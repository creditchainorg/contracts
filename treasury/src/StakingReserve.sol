// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title StakingReserve — the validator bond and reward reserve
/// @notice Custody for the largest allocation (25%). Block production depends on
///         it, so it is held by a contract with published rules rather than by a
///         wallet somebody has to be trusted with.
///
/// WHY THIS SHAPE
/// The reserve funds validator bonds and rewards. Two failure modes matter, and
/// they pull in opposite directions:
///
///   * A wallet holding it can be drained in one transaction, and the chain stops.
///   * A contract that can be emptied by whoever controls it is the same wallet
///     with extra steps.
///
/// So the authority to *allocate* is separated from the ability to *withdraw*, and
/// a per-window ceiling bounds how fast value can leave under any authority at all.
/// The governor is expected to be the Timelock, which means every allocation is
/// visible on-chain for the full delay before it can take effect.
///
/// TRANSPARENCY IS A FEATURE, NOT A SIDE EFFECT
/// Everything here is readable without permission: who is registered, how much
/// each is allocated, how much has been claimed, and what remains. A reserve whose
/// distribution cannot be checked by an outsider is indistinguishable from a
/// treasury wallet, whatever it is called.
contract StakingReserve {
    /// @notice Authority to register validators and set allocations. Expected to be
    ///         a Timelock, so changes are announced before they happen.
    address public governor;

    /// @notice Maximum that may be claimed per rolling window, across all validators.
    uint256 public outflowLimit;
    uint64 public outflowWindow;
    uint64 public windowStart;
    uint256 public windowOutflow;

    struct Validator {
        uint256 allocated;
        uint256 claimed;
        bool active;
    }

    mapping(address => Validator) public validators;
    address[] public validatorList;

    uint256 public totalAllocated;
    uint256 public totalClaimed;

    event GovernorChanged(address indexed from, address indexed to);
    event ValidatorRegistered(address indexed validator, uint256 allocated);
    event ValidatorDeactivated(address indexed validator, uint256 unclaimed);
    event Claimed(address indexed validator, uint256 amount);
    event LimitChanged(uint256 limit, uint64 window);
    event Funded(address indexed from, uint256 amount);

    error NotGovernor();
    error NotActive();
    error ZeroAddress();
    error AlreadyRegistered();
    error NothingClaimable();
    error OverAllocated(uint256 requested, uint256 available);
    error OutflowExceeded(uint256 requested, uint256 remaining);
    error TransferFailed();

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    constructor(address governor_, uint256 outflowLimit_, uint64 outflowWindow_) payable {
        if (governor_ == address(0)) revert ZeroAddress();
        governor = governor_;
        outflowLimit = outflowLimit_;
        outflowWindow = outflowWindow_;
        windowStart = uint64(block.timestamp);
    }

    receive() external payable {
        emit Funded(msg.sender, msg.value);
    }

    // ── governance ───────────────────────────────────────────────────────────

    /// @notice Register a validator and earmark part of the reserve for it.
    /// @dev Refuses to allocate more than the reserve actually holds. Promising
    ///      more than exists is how a reserve becomes insolvent on paper long
    ///      before anyone notices on-chain.
    function registerValidator(address validator, uint256 amount) external onlyGovernor {
        if (validator == address(0)) revert ZeroAddress();
        if (validators[validator].active) revert AlreadyRegistered();

        uint256 available = address(this).balance + totalClaimed - totalAllocated;
        if (amount > available) revert OverAllocated(amount, available);

        validators[validator] = Validator({ allocated: amount, claimed: 0, active: true });
        validatorList.push(validator);
        totalAllocated += amount;
        emit ValidatorRegistered(validator, amount);
    }

    /// @notice Stop a validator from claiming further. Already-claimed funds are gone.
    function deactivateValidator(address validator) external onlyGovernor {
        Validator storage v = validators[validator];
        if (!v.active) revert NotActive();
        uint256 unclaimed = v.allocated - v.claimed;
        v.active = false;
        totalAllocated -= unclaimed; // returns the unclaimed remainder to the pool
        emit ValidatorDeactivated(validator, unclaimed);
    }

    function setGovernor(address governor_) external onlyGovernor {
        if (governor_ == address(0)) revert ZeroAddress();
        emit GovernorChanged(governor, governor_);
        governor = governor_;
    }

    function setOutflowLimit(uint256 limit, uint64 window) external onlyGovernor {
        outflowLimit = limit;
        outflowWindow = window;
        emit LimitChanged(limit, window);
    }

    // ── claiming ─────────────────────────────────────────────────────────────

    /// @notice A registered validator withdraws its earmarked share.
    /// @dev State is updated before the transfer, so a re-entrant validator sees
    ///      the new totals and cannot claim twice.
    function claim(uint256 amount) external {
        Validator storage v = validators[msg.sender];
        if (!v.active) revert NotActive();
        uint256 remaining = v.allocated - v.claimed;
        if (amount == 0 || amount > remaining) revert NothingClaimable();

        _chargeOutflow(amount);

        v.claimed += amount;
        totalClaimed += amount;
        (bool ok,) = msg.sender.call{ value: amount }("");
        if (!ok) revert TransferFailed();
        emit Claimed(msg.sender, amount);
    }

    /// @dev Rolling window, reset lazily so an idle reserve does not bank unused
    ///      allowance and then permit one very large withdrawal.
    function _chargeOutflow(uint256 amount) private {
        if (outflowWindow > 0 && block.timestamp >= windowStart + outflowWindow) {
            windowStart = uint64(block.timestamp);
            windowOutflow = 0;
        }
        uint256 used = windowOutflow + amount;
        if (used > outflowLimit) revert OutflowExceeded(amount, outflowLimit - windowOutflow);
        windowOutflow = used;
    }

    // ── public views: anyone may audit the reserve ───────────────────────────

    function validatorCount() external view returns (uint256) {
        return validatorList.length;
    }

    /// @notice Reserve not yet earmarked to any validator.
    function unallocated() external view returns (uint256) {
        return address(this).balance + totalClaimed - totalAllocated;
    }

    function claimable(address validator) external view returns (uint256) {
        Validator memory v = validators[validator];
        return v.active ? v.allocated - v.claimed : 0;
    }

    function outflowRemaining() external view returns (uint256) {
        if (outflowWindow > 0 && block.timestamp >= windowStart + outflowWindow) return outflowLimit;
        return outflowLimit - windowOutflow;
    }
}
