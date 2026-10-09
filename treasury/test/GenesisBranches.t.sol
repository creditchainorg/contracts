// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { VestingWallet } from "../src/VestingWallet.sol";
import { Timelock } from "../src/Timelock.sol";
import { StakingReserve } from "../src/StakingReserve.sol";

/// @notice Every branch of the three contracts that are written into the mainnet genesis.
///
/// A genesis contract cannot be patched: the code that holds the allocation on block 0 is the code
/// that holds it for as long as the allocation exists. So each refusal is exercised, not only the
/// path that works, and the staking reserve's accounting is held to invariants under random
/// sequences of governance actions and claims.

/// Refuses every payment — stands in for a beneficiary or validator that cannot receive.
contract Refuser {
    receive() external payable {
        revert("no");
    }

    function claim(StakingReserve r, uint256 amount) external {
        r.claim(amount);
    }
}

/// Tries to take a second payment while the first is still being sent.
contract ReentrantValidator {
    StakingReserve public reserve;
    bool public tried;
    bool public secondSucceeded;

    constructor(StakingReserve r) {
        reserve = r;
    }

    function claim(uint256 amount) external {
        reserve.claim(amount);
    }

    receive() external payable {
        if (!tried) {
            tried = true;
            try reserve.claim(msg.value) { secondSucceeded = true; } catch { }
        }
    }
}

/// A timelock target that tries to execute the same action again from inside the call.
contract ReentrantTarget {
    Timelock public tl;
    bytes32 public salt;
    bool public reentered;

    function arm(Timelock t, bytes32 s) external {
        tl = t;
        salt = s;
    }

    function poke() external {
        try tl.execute(address(this), 0, abi.encodeCall(this.poke, ()), salt) { reentered = true; } catch { }
    }
}

contract TimelockBranches is Test {
    address proposer = makeAddr("proposer");
    address executor = makeAddr("executor");
    address dest = makeAddr("dest");
    Timelock tl;
    bytes32 constant SALT = bytes32(uint256(1));

    function setUp() public {
        tl = new Timelock{ value: 100 ether }(proposer, executor, 2 days);
    }

    function test_constructor_refuses_zero_roles_and_out_of_range_delays() public {
        vm.expectRevert(Timelock.ZeroAddress.selector);
        new Timelock(address(0), executor, 2 days);
        vm.expectRevert(Timelock.ZeroAddress.selector);
        new Timelock(proposer, address(0), 2 days);
        vm.expectRevert(Timelock.BadDelay.selector);
        new Timelock(proposer, executor, 1 hours - 1);
        vm.expectRevert(Timelock.BadDelay.selector);
        new Timelock(proposer, executor, 30 days + 1);
        new Timelock(proposer, executor, 1 hours); // both bounds are inclusive
        new Timelock(proposer, executor, 30 days);
    }

    function test_only_the_proposer_queues_and_cancels() public {
        vm.expectRevert(Timelock.NotProposer.selector);
        tl.queue(dest, 1, "", SALT);
        vm.prank(executor);
        vm.expectRevert(Timelock.NotProposer.selector);
        tl.queue(dest, 1, "", SALT);
        vm.expectRevert(Timelock.NotProposer.selector);
        tl.cancel(dest, 1, "", SALT);
    }

    function test_only_the_executor_executes() public {
        vm.prank(proposer);
        tl.queue(dest, 1, "", SALT);
        vm.warp(block.timestamp + 2 days);
        vm.prank(proposer);
        vm.expectRevert(Timelock.NotExecutor.selector);
        tl.execute(dest, 1, "", SALT);
    }

    function test_queue_twice_cancel_unknown_execute_unknown() public {
        vm.startPrank(proposer);
        tl.queue(dest, 1, "", SALT);
        vm.expectRevert(Timelock.AlreadyQueued.selector);
        tl.queue(dest, 1, "", SALT);
        vm.expectRevert(Timelock.NotQueued.selector);
        tl.cancel(dest, 2, "", SALT);
        vm.stopPrank();
        vm.prank(executor);
        vm.expectRevert(Timelock.NotQueued.selector);
        tl.execute(dest, 2, "", SALT);
    }

    function test_too_early_then_ready_then_expired() public {
        vm.prank(proposer);
        bytes32 id = tl.queue(dest, 1 ether, "", SALT);
        uint256 eta = block.timestamp + 2 days;
        assertFalse(tl.isReady(id));
        vm.warp(eta - 1);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(Timelock.TooEarly.selector, eta - 1, eta));
        tl.execute(dest, 1 ether, "", SALT);
        vm.warp(eta + 14 days);
        assertTrue(tl.isReady(id), "last second of the grace period");
        vm.warp(eta + 14 days + 1);
        assertFalse(tl.isReady(id));
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(Timelock.Expired.selector, eta + 14 days + 1, eta + 14 days));
        tl.execute(dest, 1 ether, "", SALT);
        // An expired action stays recorded: the proposer must cancel before queuing it again.
        vm.prank(proposer);
        vm.expectRevert(Timelock.AlreadyQueued.selector);
        tl.queue(dest, 1 ether, "", SALT);
        vm.startPrank(proposer);
        tl.cancel(dest, 1 ether, "", SALT);
        tl.queue(dest, 1 ether, "", SALT);
        vm.stopPrank();
    }

    function test_a_failing_call_reverts_and_stays_queued() public {
        Refuser r = new Refuser();
        vm.prank(proposer);
        bytes32 id = tl.queue(address(r), 1 ether, "", SALT);
        vm.warp(block.timestamp + 2 days);
        vm.prank(executor);
        vm.expectRevert(Timelock.CallFailed.selector);
        tl.execute(address(r), 1 ether, "", SALT);
        assertGt(tl.queuedAt(id), 0, "a failed execution must not consume the action");
    }

    function test_settings_change_only_through_the_timelock_itself() public {
        vm.expectRevert(Timelock.NotSelf.selector);
        tl.setDelay(1 days);
        vm.prank(proposer);
        vm.expectRevert(Timelock.NotSelf.selector);
        tl.setRoles(dest, dest);

        bytes memory d = abi.encodeCall(Timelock.setDelay, (1 days));
        bytes memory r = abi.encodeCall(Timelock.setRoles, (dest, dest));
        bytes memory bad = abi.encodeCall(Timelock.setDelay, (31 days));
        bytes memory zero = abi.encodeCall(Timelock.setRoles, (address(0), dest));
        vm.startPrank(proposer);
        tl.queue(address(tl), 0, d, SALT);
        tl.queue(address(tl), 0, r, SALT);
        tl.queue(address(tl), 0, bad, SALT);
        tl.queue(address(tl), 0, zero, SALT);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        vm.startPrank(executor);
        vm.expectRevert(Timelock.CallFailed.selector); // BadDelay inside
        tl.execute(address(tl), 0, bad, SALT);
        vm.expectRevert(Timelock.CallFailed.selector); // ZeroAddress inside
        tl.execute(address(tl), 0, zero, SALT);
        tl.execute(address(tl), 0, d, SALT);
        tl.execute(address(tl), 0, r, SALT);
        vm.stopPrank();
        assertEq(tl.delay(), 1 days);
        assertEq(tl.proposer(), dest);
        assertEq(tl.executor(), dest);
    }

    function test_an_action_cannot_execute_itself_twice() public {
        ReentrantTarget t = new ReentrantTarget();
        t.arm(tl, SALT);
        bytes memory data = abi.encodeCall(ReentrantTarget.poke, ());
        vm.prank(proposer);
        tl.queue(address(t), 0, data, SALT);
        vm.warp(block.timestamp + 2 days);
        // The target is not the executor, so its re-entry is refused regardless; make it the
        // executor to prove the queue entry is cleared before the call.
        bytes memory roles = abi.encodeCall(Timelock.setRoles, (proposer, address(t)));
        vm.prank(proposer);
        tl.queue(address(tl), 0, roles, SALT);
        vm.warp(block.timestamp + 2 days);
        vm.prank(executor);
        tl.execute(address(tl), 0, roles, SALT);
        vm.prank(address(t));
        tl.execute(address(t), 0, data, SALT);
        assertFalse(t.reentered(), "the same action executed twice");
    }

    function test_value_comes_from_the_timelock_balance() public {
        vm.prank(proposer);
        tl.queue(dest, 7 ether, "", SALT);
        vm.warp(block.timestamp + 2 days);
        vm.prank(executor);
        tl.execute(dest, 7 ether, "", SALT);
        assertEq(dest.balance, 7 ether);
        assertEq(address(tl).balance, 93 ether);
        (bool ok,) = address(tl).call{ value: 1 ether }("");
        assertTrue(ok, "the timelock accepts funds");
    }
}

contract StakingReserveBranches is Test {
    address governor = makeAddr("governor");
    address v1 = makeAddr("v1");
    address v2 = makeAddr("v2");
    StakingReserve r;
    uint256 constant LIMIT = 1_000 ether;
    uint64 constant WINDOW = 30 days;

    function setUp() public {
        r = new StakingReserve{ value: 10_000 ether }(governor, LIMIT, WINDOW);
    }

    function test_constructor_refuses_zero_governor() public {
        vm.expectRevert(StakingReserve.ZeroAddress.selector);
        new StakingReserve(address(0), LIMIT, WINDOW);
    }

    function test_governance_is_governor_only() public {
        vm.expectRevert(StakingReserve.NotGovernor.selector);
        r.registerValidator(v1, 1);
        vm.expectRevert(StakingReserve.NotGovernor.selector);
        r.deactivateValidator(v1);
        vm.expectRevert(StakingReserve.NotGovernor.selector);
        r.setGovernor(v1);
        vm.expectRevert(StakingReserve.NotGovernor.selector);
        r.setOutflowLimit(1, 1);
    }

    function test_register_refusals() public {
        vm.startPrank(governor);
        vm.expectRevert(StakingReserve.ZeroAddress.selector);
        r.registerValidator(address(0), 1);
        r.registerValidator(v1, 4_000 ether);
        vm.expectRevert(StakingReserve.AlreadyRegistered.selector);
        r.registerValidator(v1, 1);
        vm.expectRevert(abi.encodeWithSelector(StakingReserve.OverAllocated.selector, 6_000 ether + 1, 6_000 ether));
        r.registerValidator(v2, 6_000 ether + 1);
        r.registerValidator(v2, 6_000 ether); // exactly what remains
        vm.stopPrank();
        assertEq(r.unallocated(), 0);
        assertEq(r.validatorCount(), 2);
    }

    function test_claim_refusals_and_outflow_window() public {
        vm.prank(governor);
        r.registerValidator(v1, 3_000 ether);
        vm.startPrank(v2);
        vm.expectRevert(StakingReserve.NotActive.selector);
        r.claim(1);
        vm.stopPrank();
        vm.startPrank(v1);
        vm.expectRevert(StakingReserve.NothingClaimable.selector);
        r.claim(0);
        vm.expectRevert(StakingReserve.NothingClaimable.selector);
        r.claim(3_000 ether + 1);
        r.claim(600 ether);
        assertEq(r.outflowRemaining(), 400 ether);
        vm.expectRevert(abi.encodeWithSelector(StakingReserve.OutflowExceeded.selector, 401 ether, 400 ether));
        r.claim(401 ether);
        r.claim(400 ether);
        assertEq(r.outflowRemaining(), 0);
        vm.warp(block.timestamp + WINDOW);
        assertEq(r.outflowRemaining(), LIMIT, "a new window opens");
        r.claim(1_000 ether);
        vm.stopPrank();
        assertEq(v1.balance, 2_000 ether);
        assertEq(r.claimable(v1), 1_000 ether);
    }

    function test_deactivation_returns_the_unclaimed_part_and_allows_reregistration() public {
        vm.prank(governor);
        r.registerValidator(v1, 3_000 ether);
        vm.prank(v1);
        r.claim(500 ether);
        vm.prank(governor);
        r.deactivateValidator(v1);
        assertEq(r.claimable(v1), 0);
        assertEq(r.unallocated(), 9_500 ether);
        vm.prank(v1);
        vm.expectRevert(StakingReserve.NotActive.selector);
        r.claim(1);
        vm.prank(governor);
        vm.expectRevert(StakingReserve.NotActive.selector);
        r.deactivateValidator(v1);
        vm.prank(governor);
        r.registerValidator(v1, 100 ether);
        assertEq(r.claimable(v1), 100 ether);
        // The list is a history of registrations, not a set: re-registration appends.
        assertEq(r.validatorCount(), 2);
    }

    function test_window_zero_means_a_lifetime_cap() public {
        vm.startPrank(governor);
        r.setOutflowLimit(500 ether, 0);
        r.registerValidator(v1, 3_000 ether);
        vm.stopPrank();
        vm.prank(v1);
        r.claim(500 ether);
        vm.warp(block.timestamp + 365 days);
        assertEq(r.outflowRemaining(), 0, "no window: nothing resets");
        vm.prank(v1);
        vm.expectRevert(abi.encodeWithSelector(StakingReserve.OutflowExceeded.selector, 1, 0));
        r.claim(1);
    }

    /// Lowering the limit below what the current window already used makes claims fail with an
    /// arithmetic panic rather than OutflowExceeded, and the view reverts too. Funds stay put —
    /// the safe direction — but a dashboard reading outflowRemaining() breaks until the window
    /// rolls over. Recorded so a governance action that lowers the limit expects it.
    function test_lowering_the_limit_below_used_outflow_blocks_claims_until_the_window_rolls() public {
        vm.prank(governor);
        r.registerValidator(v1, 3_000 ether);
        vm.prank(v1);
        r.claim(800 ether);
        vm.prank(governor);
        r.setOutflowLimit(500 ether, WINDOW);
        vm.expectRevert(); // underflow in outflowLimit - windowOutflow
        r.outflowRemaining();
        vm.prank(v1);
        vm.expectRevert();
        r.claim(1);
        vm.warp(block.timestamp + WINDOW);
        assertEq(r.outflowRemaining(), 500 ether);
        vm.prank(v1);
        r.claim(500 ether);
    }

    function test_governor_handover() public {
        vm.prank(governor);
        vm.expectRevert(StakingReserve.ZeroAddress.selector);
        r.setGovernor(address(0));
        vm.prank(governor);
        r.setGovernor(v2);
        vm.prank(governor);
        vm.expectRevert(StakingReserve.NotGovernor.selector);
        r.registerValidator(v1, 1);
        vm.prank(v2);
        r.registerValidator(v1, 1);
    }

    function test_a_validator_that_cannot_receive_gets_nothing_and_loses_nothing() public {
        Refuser bad = new Refuser();
        vm.prank(governor);
        r.registerValidator(address(bad), 10 ether);
        vm.expectRevert(StakingReserve.TransferFailed.selector);
        bad.claim(r, 10 ether);
        assertEq(r.claimable(address(bad)), 10 ether, "a failed claim must not be booked");
        assertEq(r.outflowRemaining(), LIMIT);
    }

    function test_reentrant_claim_cannot_double_spend() public {
        ReentrantValidator rv = new ReentrantValidator(r);
        vm.prank(governor);
        r.registerValidator(address(rv), 100 ether);
        rv.claim(60 ether);
        // The nested claim of 60 exceeds the 40 left, so it fails; the books stay exact.
        assertFalse(rv.secondSucceeded());
        assertEq(address(rv).balance, 60 ether);
        assertEq(r.claimable(address(rv)), 40 ether);
    }

    function test_funding_raises_what_can_be_allocated() public {
        vm.deal(address(this), 5 ether);
        (bool ok,) = address(r).call{ value: 5 ether }("");
        assertTrue(ok);
        assertEq(r.unallocated(), 10_005 ether);
    }
}

contract VestingBranches is Test {
    address ben = makeAddr("beneficiary");

    function test_constructor_refusals() public {
        vm.expectRevert(VestingWallet.ZeroAddress.selector);
        new VestingWallet(address(0), 1, 0, 10);
        vm.expectRevert(VestingWallet.BadSchedule.selector);
        new VestingWallet(ben, 1, 0, 0);
        vm.expectRevert(VestingWallet.BadSchedule.selector);
        new VestingWallet(ben, 1, 11, 10);
        new VestingWallet(ben, 1, 10, 10); // cliff == duration: a single release at the end
    }

    function test_late_funding_vests_on_the_same_schedule() public {
        uint64 start = uint64(block.timestamp);
        VestingWallet v = new VestingWallet{ value: 100 ether }(ben, start, 0, 100);
        vm.warp(start + 50);
        assertEq(v.releasable(), 50 ether);
        v.release();
        (bool ok,) = address(v).call{ value: 100 ether }("");
        assertTrue(ok);
        assertEq(v.vestedAmount(uint64(block.timestamp)), 100 ether, "half of 200");
        assertEq(v.releasable(), 50 ether);
        vm.warp(start + 100);
        assertEq(v.releasable(), 150 ether);
    }

    function test_anyone_may_release_but_only_to_the_beneficiary() public {
        uint64 start = uint64(block.timestamp);
        VestingWallet v = new VestingWallet{ value: 10 ether }(ben, start, 0, 10);
        vm.warp(start + 10);
        vm.prank(makeAddr("stranger"));
        v.release();
        assertEq(ben.balance, 10 ether);
        vm.expectRevert(VestingWallet.NothingToRelease.selector);
        v.release();
    }

    function test_a_beneficiary_that_cannot_receive_loses_nothing() public {
        Refuser bad = new Refuser();
        uint64 start = uint64(block.timestamp);
        VestingWallet v = new VestingWallet{ value: 10 ether }(address(bad), start, 0, 10);
        vm.warp(start + 10);
        vm.expectRevert(VestingWallet.TransferFailed.selector);
        v.release();
        assertEq(v.released(), 0);
        assertEq(v.releasable(), 10 ether);
    }

    function test_schedule_is_monotonic_and_never_exceeds_the_total(uint64 a, uint64 b) public {
        uint64 start = 1_000_000;
        VestingWallet v = new VestingWallet{ value: 1_000 ether }(ben, start, 30, 1_000);
        a = uint64(bound(a, 0, 10_000_000));
        b = uint64(bound(b, a, 10_000_000));
        assertLe(v.vestedAmount(a), v.vestedAmount(b));
        assertLe(v.vestedAmount(b), 1_000 ether);
    }
}

/// Random governance actions and claims against the reserve.
contract ReserveHandler is Test {
    StakingReserve public r;
    address public governor;
    address[] public actors;
    uint256 public paidOut;

    constructor(StakingReserve r_, address governor_) {
        r = r_;
        governor = governor_;
        for (uint256 i = 0; i < 5; i++) actors.push(address(uint160(0xA000 + i)));
    }

    function register(uint256 who, uint256 amount) external {
        address a = actors[who % actors.length];
        amount = bound(amount, 1, 5_000 ether);
        vm.prank(governor);
        try r.registerValidator(a, amount) { } catch { }
    }

    function deactivate(uint256 who) external {
        vm.prank(governor);
        try r.deactivateValidator(actors[who % actors.length]) { } catch { }
    }

    function claim(uint256 who, uint256 amount) external {
        address a = actors[who % actors.length];
        amount = bound(amount, 1, 2_000 ether);
        uint256 before = a.balance;
        vm.prank(a);
        try r.claim(amount) { paidOut += a.balance - before; } catch { }
    }

    function wait(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 20 days));
    }

    function retune(uint256 limit, uint256 window) external {
        vm.prank(governor);
        r.setOutflowLimit(bound(limit, 0, 3_000 ether), uint64(bound(window, 0, 60 days)));
    }
}

contract ReserveInvariants is StdInvariant, Test {
    StakingReserve r;
    ReserveHandler h;
    uint256 constant FUNDED = 20_000 ether;

    function setUp() public {
        address governor = makeAddr("governor");
        r = new StakingReserve{ value: FUNDED }(governor, 1_000 ether, 30 days);
        h = new ReserveHandler(r, governor);
        targetContract(address(h));
    }

    /// Nothing leaves except through claims, and claims never exceed what was funded.
    function invariant_balance_is_funding_minus_payouts() public view {
        assertEq(address(r).balance, FUNDED - h.paidOut());
        assertEq(r.totalClaimed(), h.paidOut());
    }

    /// The reserve never promises more than it holds.
    function invariant_allocations_are_covered() public view {
        assertLe(r.totalAllocated(), address(r).balance + r.totalClaimed());
    }

    /// Within a window, outflow never passes the limit in force when it was charged.
    function invariant_window_outflow_bounded() public view {
        assertLe(r.windowOutflow(), 3_000 ether);
    }
}
