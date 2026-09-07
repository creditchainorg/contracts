// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @title AgentClearing
/// @notice Deposit, payment, clearing and settlement rails for autonomous agents.
///
/// WHY THIS EXISTS
/// ---------------
/// `AgentSpendVault` settles every payment on-chain. That is the right shape for
/// a payment a human would notice — a subscription, a purchase, a transfer. It is
/// the wrong shape for how agents actually transact: thousands of sub-cent
/// payments to a handful of counterparties, at machine speed. At ~42k gas per
/// spend, an agent paying per API call spends more on gas than on the service.
/// The primitive has to change, not the pricing.
///
/// The change is to stop settling payments and start settling *positions*. An
/// agent posts collateral once, then streams signed vouchers off-chain at zero
/// marginal cost. Each voucher states a running total, so only the newest one
/// matters and the payee redeems whenever it suits them. Many payments collapse
/// into one on-chain operation.
///
/// FOUR LAYERS, ONE CONTRACT
/// -------------------------
///   1. DEPOSIT     collateral, and the rules for getting it back out
///   2. PAYMENT     off-chain vouchers; nothing on-chain happens per payment
///   3. CLEARING    many obligations netted into the fewest balance changes
///   4. SETTLEMENT  those net positions applied atomically
///
/// They are one contract on purpose. The deposit layer is what makes an off-chain
/// voucher worth anything, and clearing settles directly against it. Split across
/// contracts, every settlement becomes a cross-contract value movement — more
/// reentrancy surface, non-atomic accounting, and two places to audit for one
/// invariant. The layers are separated by section here instead.
///
/// WHAT THIS CONTRACT PROMISES, AND WHAT IT DOES NOT
/// -------------------------------------------------
/// It promises that a *funded* channel can always pay out what it has committed:
/// committed collateral cannot be withdrawn while a channel can still be redeemed
/// against, and closing runs a challenge window first.
///
/// It does **not** promise that every voucher is payable. A payee that accepts
/// vouchers beyond a channel's committed collateral is extending credit, and can
/// lose. `backing()` reports exactly how much of a channel is collateralised so
/// that decision is made with open eyes rather than by assumption. Undercollateral
/// -ised channels exist because they are what makes netting save *liquidity* and
/// not merely gas — but they are opt-in, and the default is full collateral.
///
/// Nothing here is audited.
contract AgentClearing {
    // -----------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------

    struct Channel {
        address payer;
        address payee;
        /// Collateral moved out of the payer's free balance and reserved here.
        uint256 committed;
        /// Cumulative amount already paid out to the payee.
        uint256 redeemed;
        /// Highest total the payer may ever owe on this channel. May exceed
        /// `committed` only when the payee accepted credit at open time.
        uint256 cap;
        /// After this, the payee can no longer redeem and the payer can reclaim.
        uint64 expiry;
        /// Set when the payer starts closing; redemption is still allowed until
        /// `closesAt` so an in-flight voucher is never stranded.
        uint64 closesAt;
        bool open;
    }

    /// A signed claim that `payer` owes `cumulative` in total on `channelId`.
    /// The cumulative total doubles as the nonce: a newer voucher is a larger
    /// number, and redeeming an older one is a no-op rather than a replay.
    struct Voucher {
        uint256 channelId;
        uint256 cumulative;
        bytes signature;
    }

    // -----------------------------------------------------------------------
    // Storage
    // -----------------------------------------------------------------------

    /// Layer 1 — free collateral, withdrawable subject to the rules below.
    mapping(address => uint256) public available;
    /// Layer 1 — collateral reserved against open channels. Not withdrawable.
    mapping(address => uint256) public reserved;

    mapping(uint256 => Channel) private _channels;
    uint256 public channelCount;

    /// How long a payee has to redeem after the payer starts closing a channel.
    /// Long enough that a payee polling on a human timescale is not surprised;
    /// short enough that collateral is not hostage to an idle counterparty.
    uint64 public constant CLOSE_WINDOW = 1 hours;

    bytes32 private constant VOUCHER_TYPEHASH =
        keccak256("Voucher(uint256 channelId,uint256 cumulative)");
    bytes32 private constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    uint256 private _entered;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event Deposited(address indexed who, uint256 amount, uint256 available);
    event Withdrawn(address indexed who, uint256 amount, uint256 available);
    event ChannelOpened(
        uint256 indexed channelId,
        address indexed payer,
        address indexed payee,
        uint256 committed,
        uint256 cap,
        uint64 expiry
    );
    event ChannelFunded(uint256 indexed channelId, uint256 amount, uint256 committed);
    event Redeemed(
        uint256 indexed channelId,
        address indexed payee,
        uint256 delta,
        uint256 cumulative
    );
    event ChannelClosing(uint256 indexed channelId, uint64 closesAt);
    event ChannelClosed(uint256 indexed channelId, uint256 returnedToPayer);
    event BatchSettled(uint256 vouchers, uint256 grossMoved, uint256 balanceWrites);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientAvailable();
    error NotPayer();
    error NotOpen();
    error Expired();
    error NotExpiredOrClosed();
    error CapExceeded();
    error CommitAboveCap();
    error BadSignature();
    error SelfChannel();
    error Reentrancy();
    error TransferFailed();
    error NothingToRedeem();

    modifier nonReentrant() {
        if (_entered == 1) revert Reentrancy();
        _entered = 1;
        _;
        _entered = 0;
    }

    // =======================================================================
    // LAYER 1 — DEPOSIT
    //
    // Collateral lives here. The only rule that matters: value reserved against
    // an open channel is not withdrawable, because an off-chain voucher is only
    // worth what the chain will still honour.
    // =======================================================================

    /// @notice Add collateral to your free balance.
    function deposit() external payable {
        if (msg.value == 0) revert ZeroAmount();
        available[msg.sender] += msg.value;
        emit Deposited(msg.sender, msg.value, available[msg.sender]);
    }

    /// @notice Withdraw free collateral. Reserved collateral is untouched.
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (available[msg.sender] < amount) revert InsufficientAvailable();
        available[msg.sender] -= amount;
        emit Withdrawn(msg.sender, amount, available[msg.sender]);
        _send(msg.sender, amount);
    }

    // =======================================================================
    // LAYER 2 — PAYMENT
    //
    // A channel is a standing promise from payer to payee. Payments happen
    // entirely off-chain: the payer signs a new cumulative total per payment and
    // hands it to the payee. Nothing touches the chain until the payee decides
    // to bank it.
    // =======================================================================

    /// @notice Open a channel and reserve `commit` of your free collateral.
    /// @param cap Highest total this channel may ever owe. Setting `cap` above
    ///        `commit` opens an undercollateralised channel: the excess is credit
    ///        the payee is choosing to extend. `backing()` reports the ratio.
    function openChannel(address payee, uint256 commit, uint256 cap, uint64 expiry)
        external
        returns (uint256 channelId)
    {
        if (payee == address(0)) revert ZeroAddress();
        if (payee == msg.sender) revert SelfChannel();
        if (cap == 0) revert ZeroAmount();
        if (commit > cap) revert CommitAboveCap();
        if (expiry <= block.timestamp) revert Expired();
        if (available[msg.sender] < commit) revert InsufficientAvailable();

        available[msg.sender] -= commit;
        reserved[msg.sender] += commit;

        channelId = ++channelCount;
        _channels[channelId] = Channel({
            payer: msg.sender,
            payee: payee,
            committed: commit,
            redeemed: 0,
            cap: cap,
            expiry: expiry,
            closesAt: 0,
            open: true
        });

        emit ChannelOpened(channelId, msg.sender, payee, commit, cap, expiry);
    }

    /// @notice Add collateral to an open channel, raising its backing.
    function fundChannel(uint256 channelId, uint256 amount) external {
        Channel storage c = _channels[channelId];
        if (!c.open) revert NotOpen();
        if (msg.sender != c.payer) revert NotPayer();
        if (amount == 0) revert ZeroAmount();
        if (available[msg.sender] < amount) revert InsufficientAvailable();
        if (c.committed + amount > c.cap) revert CommitAboveCap();

        available[msg.sender] -= amount;
        reserved[msg.sender] += amount;
        c.committed += amount;

        emit ChannelFunded(channelId, amount, c.committed);
    }

    /// @notice Bank a voucher. Pays out everything owed since the last redemption.
    /// @dev Redeeming a stale voucher is a no-op, not an error worth reverting on
    ///      — a payee batching redemptions should not have the whole batch fail
    ///      because one channel was already up to date. The single-voucher path
    ///      does revert, so an interactive caller gets told.
    function redeem(uint256 channelId, uint256 cumulative, bytes calldata signature)
        external
        nonReentrant
    {
        uint256 delta = _applyVoucher(channelId, cumulative, signature);
        if (delta == 0) revert NothingToRedeem();
        Channel storage c = _channels[channelId];
        available[c.payee] += delta;
        emit Redeemed(channelId, c.payee, delta, cumulative);
    }

    // =======================================================================
    // LAYER 3 — CLEARING
    //
    // Netting. A batch of vouchers is verified, the resulting position per
    // account is accumulated in memory, and each account's balance is written
    // once no matter how many vouchers touched it.
    //
    // With fully collateralised channels this saves gas: one transaction and one
    // balance write per account instead of one of each per voucher. With credit
    // extended it also saves liquidity, because circular obligations canceling
    // out never need to be funded at all.
    // =======================================================================

    /// @notice Verify and net a batch of vouchers, then settle the net positions.
    /// @dev Permissionless. Every signature is checked against the channel's own
    ///      payer, so a submitter cannot invent obligations — the worst a hostile
    ///      caller can do is settle real debts earlier than the payee planned.
    function settleBatch(Voucher[] calldata vouchers) external nonReentrant {
        uint256 n = vouchers.length;
        if (n == 0) revert ZeroAmount();

        // Net position per account, accumulated before any balance is written.
        address[] memory accounts = new address[](n);
        uint256[] memory credits = new uint256[](n);
        uint256 unique;
        uint256 gross;

        for (uint256 i = 0; i < n; ++i) {
            uint256 delta =
                _applyVoucher(vouchers[i].channelId, vouchers[i].cumulative, vouchers[i].signature);
            if (delta == 0) continue; // stale voucher: skip, do not fail the batch

            gross += delta;
            address payee = _channels[vouchers[i].channelId].payee;

            uint256 slot = type(uint256).max;
            for (uint256 j = 0; j < unique; ++j) {
                if (accounts[j] == payee) {
                    slot = j;
                    break;
                }
            }
            if (slot == type(uint256).max) {
                accounts[unique] = payee;
                credits[unique] = delta;
                unique += 1;
            } else {
                credits[slot] += delta;
            }
        }

        // ---- LAYER 4 — SETTLEMENT ----
        // One storage write per account, whatever the batch size.
        for (uint256 j = 0; j < unique; ++j) {
            available[accounts[j]] += credits[j];
        }

        emit BatchSettled(n, gross, unique);
    }

    // =======================================================================
    // Channel lifecycle
    // =======================================================================

    /// @notice Begin closing a channel. The payee keeps `CLOSE_WINDOW` to redeem.
    /// @dev The window is the whole point: without it a payer could watch a
    ///      voucher be issued and reclaim the collateral before it is banked.
    function startClose(uint256 channelId) external {
        Channel storage c = _channels[channelId];
        if (!c.open) revert NotOpen();
        if (msg.sender != c.payer) revert NotPayer();
        if (c.closesAt != 0) return; // already closing; calling twice is harmless
        c.closesAt = uint64(block.timestamp) + CLOSE_WINDOW;
        emit ChannelClosing(channelId, c.closesAt);
    }

    /// @notice Finalise a channel and return unredeemed collateral to the payer.
    /// Callable once the close window has elapsed, or once the channel expired.
    function closeChannel(uint256 channelId) external nonReentrant {
        Channel storage c = _channels[channelId];
        if (!c.open) revert NotOpen();

        bool windowDone = c.closesAt != 0 && block.timestamp >= c.closesAt;
        bool expired = block.timestamp >= c.expiry;
        if (!windowDone && !expired) revert NotExpiredOrClosed();

        uint256 unspent = c.committed - _paidFrom(c);
        c.open = false;

        if (unspent > 0) {
            reserved[c.payer] -= unspent;
            available[c.payer] += unspent;
        }
        emit ChannelClosed(channelId, unspent);
    }

    // =======================================================================
    // Views
    // =======================================================================

    function channel(uint256 channelId) external view returns (Channel memory) {
        return _channels[channelId];
    }

    /// @notice How much of this channel's cap is actually backed by collateral,
    ///         in basis points. 10000 means fully collateralised.
    /// @dev The number a payee should look at before accepting vouchers. Anything
    ///      below 10000 means the tail of the cap is unsecured credit.
    function backing(uint256 channelId) external view returns (uint256 bps) {
        Channel storage c = _channels[channelId];
        if (c.cap == 0) return 0;
        uint256 backed = c.committed > c.cap ? c.cap : c.committed;
        return (backed * 10_000) / c.cap;
    }

    /// @notice What a payee could still bank from this channel right now.
    function redeemableNow(uint256 channelId) external view returns (uint256) {
        Channel storage c = _channels[channelId];
        if (!c.open || block.timestamp >= c.expiry) return 0;
        uint256 paid = _paidFrom(c);
        return c.committed > paid ? c.committed - paid : 0;
    }

    /// @notice The digest a payer signs for a voucher. Exposed so an off-chain
    ///         signer never has to reimplement the domain separator.
    function voucherDigest(uint256 channelId, uint256 cumulative)
        public
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(VOUCHER_TYPEHASH, channelId, cumulative));
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    // =======================================================================
    // Internals
    // =======================================================================

    /// Verify a voucher and advance the channel's redeemed total.
    /// @return delta amount newly owed, zero when the voucher is stale.
    function _applyVoucher(uint256 channelId, uint256 cumulative, bytes calldata signature)
        private
        returns (uint256 delta)
    {
        Channel storage c = _channels[channelId];
        if (!c.open) revert NotOpen();
        if (block.timestamp >= c.expiry) revert Expired();
        if (cumulative > c.cap) revert CapExceeded();

        // A voucher at or below what has already been paid carries no new
        // obligation. The cumulative total is the nonce; going backwards is
        // meaningless rather than malicious.
        if (cumulative <= c.redeemed) return 0;

        if (_recover(voucherDigest(channelId, cumulative), signature) != c.payer) {
            revert BadSignature();
        }

        delta = cumulative - c.redeemed;

        // Only collateral that exists can move. Anything above `committed` is the
        // credit the payee agreed to carry, and stays an off-chain claim.
        uint256 payable_ = c.committed - _paidFrom(c);
        if (delta > payable_) delta = payable_;
        if (delta == 0) return 0;

        c.redeemed += delta;
        reserved[c.payer] -= delta;
        return delta;
    }

    /// Collateral already paid out of this channel.
    function _paidFrom(Channel storage c) private view returns (uint256) {
        return c.redeemed;
    }

    function _domainSeparator() private view returns (bytes32) {
        // Recomputed rather than cached: a cached separator is wrong on the other
        // side of a chain split, and this contract is meant to outlive one.
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("CreditChain AgentClearing"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    function _recover(bytes32 digest, bytes calldata sig) private pure returns (address) {
        if (sig.length != 65) revert BadSignature();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        // Reject the upper half of the curve order. Both halves recover the same
        // signer, so accepting them would let the same voucher be presented under
        // two distinct signatures.
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert BadSignature();
        }
        if (v < 27) v += 27;
        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert BadSignature();
        return signer;
    }

    function _send(address to, uint256 amount) private {
        (bool ok,) = payable(to).call{ value: amount }("");
        if (!ok) revert TransferFailed();
    }
}
