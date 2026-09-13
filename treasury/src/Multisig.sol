// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Multisig — M-of-N approval before value moves
/// @notice Custody for the management, ecosystem and liquidity allocations.
///
/// WHY
/// A treasury behind one key fails the moment that key does — a stolen laptop, a
/// lost phone, one person leaving. Requiring M of N signers turns a single point of
/// failure into a quorum, and makes every spend an event with a visible on-chain
/// record of who approved it.
///
/// SCOPE, STATED HONESTLY
/// This is a deliberately small multisig: propose, confirm, execute, with owner
/// changes going through the same quorum. It is not Safe. It has no modules, no
/// off-chain signature aggregation, and no recovery flow. For an allocation of real
/// size, use a Safe deployment that has been audited and battle-tested for years —
/// this exists so testnet can exercise the ECONOMIC pattern end to end without
/// waiting on that decision, and so `custody: multisig` means something concrete.
contract Multisig {
    address[] public owners;
    mapping(address => bool) public isOwner;
    uint256 public threshold;
    /// @notice Pending proposals belong to one owner configuration. Rotation
    /// invalidates them; approvals from removed owners must never carry forward.
    uint256 public ownerEpoch;
    mapping(uint256 => uint256) public transactionEpoch;

    struct Tx {
        address to;
        uint256 value;
        bytes data;
        bool executed;
        uint256 confirmations;
    }

    Tx[] public transactions;
    mapping(uint256 => mapping(address => bool)) public confirmed;

    event Submitted(uint256 indexed txId, address indexed by, address to, uint256 value);
    event Confirmed(uint256 indexed txId, address indexed by, uint256 count);
    event Revoked(uint256 indexed txId, address indexed by);
    event Executed(uint256 indexed txId);
    event OwnersChanged(uint256 ownerCount, uint256 threshold);

    error NotOwner();
    error NotSelf();
    error BadOwnerSet();
    error NoSuchTx();
    error AlreadyExecuted();
    error AlreadyConfirmed();
    error NotConfirmed();
    error BelowThreshold(uint256 have, uint256 need);
    error CallFailed();
    error StaleOwnerSet();

    modifier onlyOwner() {
        if (!isOwner[msg.sender]) revert NotOwner();
        _;
    }

    /// @dev Owner changes must come from the multisig itself, so they need the same
    ///      quorum as spending. An owner who could unilaterally add an owner would
    ///      make the threshold decorative.
    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    constructor(address[] memory owners_, uint256 threshold_) payable {
        _setOwners(owners_, threshold_);
    }

    receive() external payable { }

    function _setOwners(address[] memory owners_, uint256 threshold_) private {
        if (owners_.length == 0 || threshold_ == 0 || threshold_ > owners_.length) revert BadOwnerSet();

        for (uint256 i = 0; i < owners.length; ++i) isOwner[owners[i]] = false;
        delete owners;

        for (uint256 i = 0; i < owners_.length; ++i) {
            address o = owners_[i];
            // A zero or duplicate owner would inflate the owner count without adding
            // a real signer, quietly weakening the threshold it is measured against.
            if (o == address(0) || isOwner[o]) revert BadOwnerSet();
            isOwner[o] = true;
            owners.push(o);
        }
        threshold = threshold_;
        ownerEpoch += 1;
        emit OwnersChanged(owners_.length, threshold_);
    }

    function submit(address to, uint256 value, bytes calldata data) external onlyOwner returns (uint256 txId) {
        txId = transactions.length;
        transactionEpoch[txId] = ownerEpoch;
        transactions.push(Tx({ to: to, value: value, data: data, executed: false, confirmations: 0 }));
        emit Submitted(txId, msg.sender, to, value);
        _confirm(txId);
    }

    function confirm(uint256 txId) external onlyOwner {
        _confirm(txId);
    }

    function _confirm(uint256 txId) private {
        if (txId >= transactions.length) revert NoSuchTx();
        Tx storage t = transactions[txId];
        if (t.executed) revert AlreadyExecuted();
        if (transactionEpoch[txId] != ownerEpoch) revert StaleOwnerSet();
        if (confirmed[txId][msg.sender]) revert AlreadyConfirmed();
        confirmed[txId][msg.sender] = true;
        t.confirmations += 1;
        emit Confirmed(txId, msg.sender, t.confirmations);
    }

    /// @notice Withdraw a confirmation while the transaction is still pending.
    function revoke(uint256 txId) external onlyOwner {
        if (txId >= transactions.length) revert NoSuchTx();
        Tx storage t = transactions[txId];
        if (t.executed) revert AlreadyExecuted();
        if (transactionEpoch[txId] != ownerEpoch) revert StaleOwnerSet();
        if (!confirmed[txId][msg.sender]) revert NotConfirmed();
        confirmed[txId][msg.sender] = false;
        t.confirmations -= 1;
        emit Revoked(txId, msg.sender);
    }

    /// @notice Execute once the threshold is met. Callable by any owner.
    /// @dev Marked executed BEFORE the external call, so a re-entrant target cannot
    ///      run the same transaction twice.
    function execute(uint256 txId) external onlyOwner {
        if (txId >= transactions.length) revert NoSuchTx();
        Tx storage t = transactions[txId];
        if (t.executed) revert AlreadyExecuted();
        if (transactionEpoch[txId] != ownerEpoch) revert StaleOwnerSet();
        if (t.confirmations < threshold) revert BelowThreshold(t.confirmations, threshold);

        t.executed = true;
        (bool ok,) = t.to.call{ value: t.value }(t.data);
        if (!ok) revert CallFailed();
        emit Executed(txId);
    }

    /// @notice Replace the owner set and threshold. Only via the multisig itself.
    /// All unexecuted proposals become stale, including on a threshold-only
    /// change. Re-submit under the new owner set; historical approvals remain
    /// readable but cannot authorize new actions.
    function setOwners(address[] calldata owners_, uint256 threshold_) external onlySelf {
        _setOwners(owners_, threshold_);
    }

    function ownerCount() external view returns (uint256) {
        return owners.length;
    }

    function transactionCount() external view returns (uint256) {
        return transactions.length;
    }
}
