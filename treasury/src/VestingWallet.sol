// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title VestingWallet — cliff + linear release of a CCC allocation
/// @notice Holds the team/contributor allocation so the schedule is enforced by
///         the chain rather than promised in a document.
///
/// WHY A CONTRACT AND NOT A WALLET
/// A vesting schedule held in an EOA is a statement of intent: the holder can move
/// everything on day one and nobody can stop them or even see it coming. Held here,
/// the schedule is a rail — an investor can verify the cliff and the curve from
/// chain state alone, without trusting anyone's word. That difference is the whole
/// reason `build-genesis.py` refuses `custody: eoa` for the team role.
///
/// SCHEDULE
///   t <  start + cliff            -> 0 releasable
///   t >= start + duration         -> everything releasable
///   otherwise                     -> linear in elapsed time from `start`
///
/// The cliff does not delay the curve, it gates it: at the moment the cliff passes,
/// everything accrued since `start` becomes releasable at once. That is the common
/// convention and it is stated here because the alternative (curve begins at cliff)
/// is equally common and silently changes the numbers.
contract VestingWallet {
    address public immutable beneficiary;
    uint64 public immutable start;
    uint64 public immutable cliff;
    uint64 public immutable duration;

    uint256 public released;

    event Released(uint256 amount);
    event Funded(address indexed from, uint256 amount);

    error NotBeneficiary();
    error NothingToRelease();
    error TransferFailed();
    error BadSchedule();
    error ZeroAddress();

    /// @param beneficiary_ Who receives the vested CCC.
    /// @param start_       Unix time the schedule begins accruing.
    /// @param cliffSeconds Seconds after `start_` before anything is releasable.
    /// @param duration_    Total seconds from `start_` to fully vested.
    constructor(address beneficiary_, uint64 start_, uint64 cliffSeconds, uint64 duration_) payable {
        if (beneficiary_ == address(0)) revert ZeroAddress();
        // A cliff past the end would vest everything in one step and quietly turn a
        // vesting contract into a time lock — almost always a typo, never intended.
        if (duration_ == 0 || cliffSeconds > duration_) revert BadSchedule();
        beneficiary = beneficiary_;
        start = start_;
        cliff = start_ + cliffSeconds;
        duration = duration_;
    }

    receive() external payable {
        emit Funded(msg.sender, msg.value);
    }

    /// @notice Total that has vested by `timestamp`, released or not.
    function vestedAmount(uint64 timestamp) public view returns (uint256) {
        uint256 total = address(this).balance + released;
        if (timestamp < cliff) return 0;
        if (timestamp >= start + duration) return total;
        return (total * (timestamp - start)) / duration;
    }

    /// @notice How much can be withdrawn right now.
    function releasable() public view returns (uint256) {
        return vestedAmount(uint64(block.timestamp)) - released;
    }

    /// @notice Send the currently releasable amount to the beneficiary.
    /// @dev Anyone may call it — the destination is fixed at construction, so a
    ///      third party paying gas can only help the beneficiary. `released` is
    ///      updated before the transfer, so a re-entrant beneficiary sees the new
    ///      value and cannot drain more than it is owed.
    function release() external {
        uint256 amount = releasable();
        if (amount == 0) revert NothingToRelease();
        released += amount;
        (bool ok,) = beneficiary.call{ value: amount }("");
        if (!ok) revert TransferFailed();
        emit Released(amount);
    }
}
