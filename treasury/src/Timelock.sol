// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Timelock — every governance action is visible before it can happen
/// @notice Custody for the governance allocation and the intended admin of any
///         upgradeable protocol contract.
///
/// WHY A DELAY IS THE POINT
/// A multisig makes governance require agreement. A timelock makes it require
/// agreement *in advance and in public*. Queued actions are on-chain for the full
/// delay before they can execute, so anyone — token holders, exchanges, users —
/// can see a parameter change or an upgrade coming and react while they still can.
/// Without it, "governance" is indistinguishable from an admin key, however many
/// people hold it.
///
/// The proposer is expected to be a multisig; this contract deliberately does not
/// re-implement quorum. Separation of concerns: the multisig decides *whether*,
/// the timelock decides *when* and guarantees *notice*.
contract Timelock {
    /// @notice May queue and cancel. Expected to be a multisig.
    address public proposer;
    /// @notice May execute a matured action. Often the same as proposer.
    address public executor;
    /// @notice Seconds an action must sit queued before it may execute.
    uint256 public delay;

    /// @dev Bounds exist so a mis-set delay cannot make governance either
    ///      instantaneous (defeating the purpose) or permanently stuck.
    uint256 public constant MIN_DELAY = 1 hours;
    uint256 public constant MAX_DELAY = 30 days;
    /// @dev After this, a matured action expires. Otherwise a forgotten proposal
    ///      stays executable forever and becomes a latent authority nobody tracks.
    uint256 public constant GRACE_PERIOD = 14 days;

    mapping(bytes32 => uint256) public queuedAt;

    event Queued(bytes32 indexed id, address target, uint256 value, bytes data, uint256 eta);
    event Executed(bytes32 indexed id, address target, uint256 value, bytes data);
    event Cancelled(bytes32 indexed id);
    event DelayChanged(uint256 oldDelay, uint256 newDelay);
    event RolesChanged(address proposer, address executor);

    error NotProposer();
    error NotExecutor();
    error NotSelf();
    error BadDelay();
    error AlreadyQueued();
    error NotQueued();
    error TooEarly(uint256 nowTs, uint256 eta);
    error Expired(uint256 nowTs, uint256 deadline);
    error CallFailed();
    error ZeroAddress();

    modifier onlyProposer() {
        if (msg.sender != proposer) revert NotProposer();
        _;
    }

    modifier onlyExecutor() {
        if (msg.sender != executor) revert NotExecutor();
        _;
    }

    /// @dev Changing the delay or the roles must itself go through the timelock,
    ///      or the delay could be set to zero in one step and every guarantee here
    ///      would evaporate at the moment it was needed.
    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    constructor(address proposer_, address executor_, uint256 delay_) payable {
        if (proposer_ == address(0) || executor_ == address(0)) revert ZeroAddress();
        if (delay_ < MIN_DELAY || delay_ > MAX_DELAY) revert BadDelay();
        proposer = proposer_;
        executor = executor_;
        delay = delay_;
    }

    receive() external payable { }

    function actionId(address target, uint256 value, bytes calldata data, bytes32 salt)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(target, value, data, salt));
    }

    /// @notice Queue an action. It becomes executable after `delay` and expires
    ///         GRACE_PERIOD later.
    function queue(address target, uint256 value, bytes calldata data, bytes32 salt)
        external
        onlyProposer
        returns (bytes32 id)
    {
        id = actionId(target, value, data, salt);
        if (queuedAt[id] != 0) revert AlreadyQueued();
        uint256 eta = block.timestamp + delay;
        queuedAt[id] = eta;
        emit Queued(id, target, value, data, eta);
    }

    function cancel(address target, uint256 value, bytes calldata data, bytes32 salt) external onlyProposer {
        bytes32 id = actionId(target, value, data, salt);
        if (queuedAt[id] == 0) revert NotQueued();
        delete queuedAt[id];
        emit Cancelled(id);
    }

    /// @notice Execute a matured action.
    /// @dev The queue entry is cleared BEFORE the external call so a re-entrant
    ///      target cannot execute the same action twice.
    function execute(address target, uint256 value, bytes calldata data, bytes32 salt) external onlyExecutor {
        bytes32 id = actionId(target, value, data, salt);
        uint256 eta = queuedAt[id];
        if (eta == 0) revert NotQueued();
        if (block.timestamp < eta) revert TooEarly(block.timestamp, eta);
        if (block.timestamp > eta + GRACE_PERIOD) revert Expired(block.timestamp, eta + GRACE_PERIOD);

        delete queuedAt[id];
        (bool ok,) = target.call{ value: value }(data);
        if (!ok) revert CallFailed();
        emit Executed(id, target, value, data);
    }

    function setDelay(uint256 newDelay) external onlySelf {
        if (newDelay < MIN_DELAY || newDelay > MAX_DELAY) revert BadDelay();
        emit DelayChanged(delay, newDelay);
        delay = newDelay;
    }

    function setRoles(address proposer_, address executor_) external onlySelf {
        if (proposer_ == address(0) || executor_ == address(0)) revert ZeroAddress();
        proposer = proposer_;
        executor = executor_;
        emit RolesChanged(proposer_, executor_);
    }

    function isReady(bytes32 id) external view returns (bool) {
        uint256 eta = queuedAt[id];
        return eta != 0 && block.timestamp >= eta && block.timestamp <= eta + GRACE_PERIOD;
    }
}
