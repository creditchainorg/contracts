// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import { IAgentMandateVault } from "./IAgentMandateVault.sol";
import { AssetTransfer } from "../lib/AssetTransfer.sol";
import { SignatureCheck } from "../lib/SignatureCheck.sol";

/// @title AgentMandateVault — ERC-AGM v2 reference implementation
/// @notice An owner funds a mandate in the native coin or any ERC-20 and names an agent. The agent
///         pays recipients on its own — directly, or by signing and letting anyone relay — and the
///         contract enforces every rail on every payment:
///
///           budget        lifetime ceiling on payments + relay fees
///           perTxMax      ceiling on one payment
///           window        ceiling on payments + fees per rolling window
///           allowlist     optional: only pre-approved recipients
///           expiry        the mandate stops on its own
///           maxRelayFee   ceiling on what a relayer may take per signed payment
///
///         The owner can pause, rotate the agent's key, withdraw, or revoke and take back the
///         unspent balance at any time. No one else — not the deployer, not an admin, there is
///         none — can move a mandate's funds.
///
/// @dev The owner's worst case is always `min(budget, balance)`, whatever the agent signs and
///      whoever relays it: fees are counted against the budget and window exactly like payments.
///
///      Deployed at the same address on every EVM chain through the deterministic-deployment proxy.
///      Tokens whose balances change without a transfer (rebasing, interest-bearing by balance)
///      are not supported: the vault accounts for what it received, and such a token makes
///      that number drift from what it holds. Fee-on-transfer tokens are supported on the way in.
///
///      SECURITY STATUS: not yet audited.
contract AgentMandateVault is IAgentMandateVault {
    using AssetTransfer for address;

    /// Storage layout, seven slots per mandate. Amounts are uint128: 3.4e38 units, more than any
    /// token's real supply; a larger amount reverts with {AmountTooLarge} rather than truncating.
    struct Record {
        address owner; // ─┐ slot 0
        uint64 expiry; //  │
        bool allowlistEnabled; //
        bool paused; //    │
        bool revoked; //  ─┘
        address agent; // ─┐ slot 1
        uint64 windowSeconds; // ┘
        address asset; // ─┐ slot 2
        uint64 windowStart; // ┘
        uint128 budget; // ─┐ slot 3
        uint128 spent; //  ─┘
        uint128 balance; // ─┐ slot 4
        uint128 perTxMax; // ┘
        uint128 windowLimit; // ─┐ slot 5
        uint128 windowSpent; // ─┘
        uint128 maxRelayFee; // ─┐ slot 6
        uint128 spentToOwner; // ┘
    }

    bytes32 public constant SPEND_AUTHORIZATION_TYPEHASH = keccak256(
        "SpendAuthorization(uint256 mandateId,address recipient,uint256 amount,bytes32 receipt,uint256 fee,uint256 nonce,uint256 deadline)"
    );
    bytes32 private constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant NAME_HASH = keccak256("ERC-AGM AgentMandateVault");
    bytes32 private constant VERSION_HASH = keccak256("2");
    /// Transient-storage slot of the reentrancy lock: keccak256("erc-agm.vault.lock") - 1.
    bytes32 private constant LOCK_SLOT =
        0xbdc602d88bf0be69937ed8e15a3963f8da14a78fbf850d70fcbd5d3aec7ed8bf;

    uint256 public mandateCount;
    mapping(uint256 => Record) private _m;
    mapping(uint256 => mapping(address => bool)) public allowlisted;
    mapping(uint256 => mapping(uint256 => bool)) public nonceUsed;

    modifier nonReentrant() {
        bytes32 slot = LOCK_SLOT;
        uint256 locked;
        assembly ("memory-safe") {
            locked := tload(slot)
        }
        if (locked != 0) revert Reentrancy();
        assembly ("memory-safe") {
            tstore(slot, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }

    // ───────────────────────────── owner: create, fund, configure ─────────────────────────────

    /// @inheritdoc IAgentMandateVault
    function createMandate(MandateTerms calldata t)
        external
        payable
        nonReentrant
        returns (uint256 mandateId)
    {
        if (t.agent == address(0)) revert ZeroAddress();
        uint256 received = _receive(t.asset, t.amount);

        mandateId = ++mandateCount;
        Record storage m = _m[mandateId];
        m.owner = msg.sender;
        m.expiry = t.expiry;
        m.allowlistEnabled = t.allowlistEnabled;
        m.agent = t.agent;
        m.windowSeconds = t.windowSeconds;
        m.asset = t.asset;
        m.windowStart = uint64(block.timestamp);
        m.budget = _u128(t.budget);
        m.balance = _u128(received);
        m.perTxMax = _u128(t.perTxMax);
        m.windowLimit = _u128(t.windowLimit);
        m.maxRelayFee = _u128(t.maxRelayFee);

        _emitCreated(mandateId, t);
        emit MandateFunded(mandateId, msg.sender, received, received);
    }

    /// Split out of createMandate only to keep its stack shallow.
    function _emitCreated(uint256 mandateId, MandateTerms calldata t) private {
        emit MandateCreated(
            mandateId,
            msg.sender,
            t.agent,
            t.asset,
            t.budget,
            t.perTxMax,
            t.windowLimit,
            t.windowSeconds,
            t.expiry,
            t.allowlistEnabled,
            t.maxRelayFee
        );
    }

    /// @inheritdoc IAgentMandateVault
    /// @dev Anyone may fund (a treasury topping up an agent, say). A revoked mandate takes nothing:
    ///      its agent can never spend again, so the money would only sit there.
    function fund(uint256 mandateId, uint256 amount) external payable nonReentrant {
        Record storage m = _m[mandateId];
        if (m.owner == address(0) || m.revoked) revert MandateInactive();
        uint256 received = _receive(m.asset, amount);
        uint128 newBalance = _u128(uint256(m.balance) + received);
        m.balance = newBalance;
        emit MandateFunded(mandateId, msg.sender, received, newBalance);
    }

    /// @inheritdoc IAgentMandateVault
    function allowRecipient(uint256 mandateId, address recipient, bool allowed) external {
        if (msg.sender != _m[mandateId].owner) revert NotOwner();
        if (recipient == address(0)) revert ZeroAddress();
        allowlisted[mandateId][recipient] = allowed;
        emit RecipientAllowed(mandateId, recipient, allowed);
    }

    /// @inheritdoc IAgentMandateVault
    /// @dev Signatures by the previous agent stop working at once: every signed spend is checked
    ///      against the agent at the time it is relayed.
    function rotateAgent(uint256 mandateId, address agent) external {
        Record storage m = _m[mandateId];
        if (msg.sender != m.owner) revert NotOwner();
        if (agent == address(0)) revert ZeroAddress();
        address previous = m.agent;
        m.agent = agent;
        emit AgentRotated(mandateId, previous, agent);
    }

    /// @inheritdoc IAgentMandateVault
    function setPaused(uint256 mandateId, bool paused) external {
        Record storage m = _m[mandateId];
        if (msg.sender != m.owner) revert NotOwner();
        if (m.revoked) revert MandateInactive();
        m.paused = paused;
        emit MandatePaused(mandateId, paused);
    }

    /// @inheritdoc IAgentMandateVault
    function revoke(uint256 mandateId) external nonReentrant {
        Record storage m = _m[mandateId];
        if (msg.sender != m.owner) revert NotOwner();
        m.revoked = true;
        uint256 refund = m.balance;
        m.balance = 0;
        m.asset.send(m.owner, refund);
        emit MandateRevoked(mandateId, m.owner, refund);
    }

    /// @inheritdoc IAgentMandateVault
    function withdraw(uint256 mandateId, uint256 amount) external nonReentrant {
        Record storage m = _m[mandateId];
        if (msg.sender != m.owner) revert NotOwner();
        if (amount == 0) revert ZeroAmount();
        if (amount > m.balance) revert InsufficientBalance();
        // forge-lint: disable-next-line(unsafe-typecast) amount <= balance, a uint128
        m.balance -= uint128(amount);
        m.asset.send(m.owner, amount);
        emit Withdrawn(mandateId, m.owner, amount);
    }

    // ───────────────────────────── agent: spend ─────────────────────────────

    /// @inheritdoc IAgentMandateVault
    function spend(uint256 mandateId, address recipient, uint256 amount, bytes32 receipt)
        external
        nonReentrant
    {
        Record storage m = _m[mandateId];
        if (msg.sender != m.agent) revert NotAgent();
        _spend(mandateId, m, recipient, amount, receipt, 0, address(0));
    }

    /// @inheritdoc IAgentMandateVault
    /// @dev Permissionless to submit. The signature binds recipient, amount, receipt, fee, nonce
    ///      and deadline, so a relayer can choose only *when* to submit, never what is paid. The
    ///      fee goes to whoever submits; the owner's `maxRelayFee` caps it (0 = free relays only).
    function spendWithSignature(SpendAuthorization calldata auth, bytes calldata signature)
        external
        nonReentrant
    {
        Record storage m = _m[auth.mandateId];
        if (m.owner == address(0)) revert MandateInactive();
        if (block.timestamp > auth.deadline) revert SignatureExpired();
        if (nonceUsed[auth.mandateId][auth.nonce]) revert NonceUsed();
        if (auth.fee > m.maxRelayFee) revert FeeExceedsCap();
        if (!SignatureCheck.isValid(m.agent, spendDigest(auth), signature)) revert BadSignature();

        nonceUsed[auth.mandateId][auth.nonce] = true;
        _spend(auth.mandateId, m, auth.recipient, auth.amount, auth.receipt, auth.fee, msg.sender);
        if (auth.fee != 0) emit RelayFeePaid(auth.mandateId, msg.sender, auth.fee, auth.nonce);
    }

    /// Every rail, then effects, then the transfers. Reverts move nothing.
    function _spend(
        uint256 mandateId,
        Record storage m,
        address recipient,
        uint256 amount,
        bytes32 receipt,
        uint256 fee,
        address relayer
    ) private {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (m.revoked || m.paused) revert MandateInactive();
        if (m.expiry != 0 && block.timestamp > m.expiry) revert MandateInactive();
        if (m.allowlistEnabled && !allowlisted[mandateId][recipient]) revert RecipientNotAllowed();
        if (m.perTxMax != 0 && amount > m.perTxMax) revert PerTxExceeded();

        uint256 total = amount + fee;
        uint256 spentAfter = uint256(m.spent) + total;
        if (m.budget != 0 && spentAfter > m.budget) revert BudgetExceeded();
        if (total > m.balance) revert InsufficientBalance();

        if (m.windowLimit != 0) {
            uint256 windowSpent = m.windowSpent;
            if (block.timestamp >= uint256(m.windowStart) + m.windowSeconds) {
                m.windowStart = uint64(block.timestamp);
                windowSpent = 0;
            }
            windowSpent += total;
            if (windowSpent > m.windowLimit) revert WindowExceeded();
            // forge-lint: disable-next-line(unsafe-typecast) <= windowLimit, a uint128
            m.windowSpent = uint128(windowSpent);
        }

        m.spent = _u128(spentAfter);
        // forge-lint: disable-next-line(unsafe-typecast) total <= balance, a uint128
        m.balance -= uint128(total);
        // forge-lint: disable-next-line(unsafe-typecast) amount <= total, checked above
        if (recipient == m.owner) m.spentToOwner += uint128(amount);

        address asset = m.asset;
        asset.send(recipient, amount);
        if (fee != 0) asset.send(relayer, fee);

        emit AgentPayment(mandateId, m.agent, recipient, amount, receipt, spentAfter);
    }

    // ───────────────────────────── views ─────────────────────────────

    /// @inheritdoc IAgentMandateVault
    function mandate(uint256 mandateId) external view returns (Mandate memory out) {
        Record storage m = _m[mandateId];
        out = Mandate({
            owner: m.owner,
            agent: m.agent,
            asset: m.asset,
            budget: m.budget,
            spent: m.spent,
            balance: m.balance,
            perTxMax: m.perTxMax,
            windowLimit: m.windowLimit,
            windowSeconds: m.windowSeconds,
            windowStart: m.windowStart,
            windowSpent: m.windowSpent,
            maxRelayFee: m.maxRelayFee,
            spentToOwner: m.spentToOwner,
            expiry: m.expiry,
            allowlistEnabled: m.allowlistEnabled,
            paused: m.paused,
            revoked: m.revoked
        });
    }

    /// @inheritdoc IAgentMandateVault
    /// @dev The largest single direct payment possible right now, all rails combined. A relayed
    ///      payment's fee comes out of the same budget, window and balance.
    function spendableNow(uint256 mandateId) external view returns (uint256 cap) {
        Record storage m = _m[mandateId];
        if (m.owner == address(0) || m.revoked || m.paused) return 0;
        if (m.expiry != 0 && block.timestamp > m.expiry) return 0;
        cap = m.balance;
        if (m.budget != 0) {
            uint256 left = m.budget > m.spent ? m.budget - m.spent : 0;
            if (left < cap) cap = left;
        }
        if (m.windowLimit != 0) {
            uint256 left;
            if (block.timestamp >= uint256(m.windowStart) + m.windowSeconds) {
                left = m.windowLimit;
            } else {
                left = m.windowLimit > m.windowSpent ? m.windowLimit - m.windowSpent : 0;
            }
            if (left < cap) cap = left;
        }
        if (m.perTxMax != 0 && m.perTxMax < cap) cap = m.perTxMax;
    }

    /// @inheritdoc IAgentMandateVault
    function spendDigest(SpendAuthorization calldata a) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                SPEND_AUTHORIZATION_TYPEHASH,
                a.mandateId,
                a.recipient,
                a.amount,
                a.receipt,
                a.fee,
                a.nonce,
                a.deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    /// @notice EIP-712 domain separator. Recomputed on every call, never cached, so it stays
    ///         correct on both sides of a chain split.
    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this))
        );
    }

    /// @notice ERC-165.
    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == type(IAgentMandateVault).interfaceId;
    }

    // ───────────────────────────── internals ─────────────────────────────

    /// Take in `amount` of `asset` from msg.sender; return what actually arrived.
    function _receive(address asset, uint256 amount) private returns (uint256) {
        if (asset == address(0)) {
            if (msg.value != amount) revert WrongValue();
            return amount;
        }
        if (msg.value != 0) revert WrongValue();
        return asset.pull(msg.sender, amount);
    }

    function _u128(uint256 x) private pure returns (uint128) {
        if (x > type(uint128).max) revert AmountTooLarge();
        // forge-lint: disable-next-line(unsafe-typecast) range checked on the line above
        return uint128(x);
    }
}
