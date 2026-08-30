// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { VestingWallet } from "../src/VestingWallet.sol";
import { Multisig } from "../src/Multisig.sol";
import { Timelock } from "../src/Timelock.sol";

/// @notice Tests for the custody rails the mainnet genesis allocation depends on.
///
/// These contracts are what `custody: multisig / timelock / contract` resolves to
/// in the allocation manifest, so the properties asserted here are the ones that
/// make those labels mean anything. Several tests assert the ABSENCE of a
/// capability — that a non-owner cannot spend, that a delay cannot be skipped —
/// because that is where the value actually sits.
contract VestingWalletTest is Test {
    address beneficiary = makeAddr("beneficiary");
    VestingWallet v;
    uint64 start;
    uint64 constant CLIFF = 365 days;
    uint64 constant DURATION = 4 * 365 days;
    uint256 constant AMOUNT = 120_000_000 ether;

    function setUp() public {
        start = uint64(block.timestamp);
        v = new VestingWallet{ value: AMOUNT }(beneficiary, start, CLIFF, DURATION);
    }

    function test_nothing_vests_before_the_cliff() public {
        vm.warp(start + CLIFF - 1);
        assertEq(v.releasable(), 0, "released before cliff");
        vm.expectRevert(VestingWallet.NothingToRelease.selector);
        v.release();
    }

    /// The cliff gates the curve rather than delaying it: at the instant it passes,
    /// everything accrued since `start` becomes available at once.
    function test_cliff_releases_accrued_amount_at_once() public {
        vm.warp(start + CLIFF);
        assertEq(v.releasable(), AMOUNT * CLIFF / DURATION, "cliff payout wrong");
    }

    function test_fully_vested_after_duration() public {
        vm.warp(start + DURATION);
        assertEq(v.releasable(), AMOUNT);
        v.release();
        assertEq(beneficiary.balance, AMOUNT);
        assertEq(address(v).balance, 0);
    }

    function test_linear_between_cliff_and_end() public {
        vm.warp(start + DURATION / 2);
        assertEq(v.releasable(), AMOUNT / 2, "not linear at midpoint");
    }

    /// Releasing twice at the same instant must not pay twice.
    function test_cannot_double_release() public {
        vm.warp(start + DURATION / 2);
        v.release();
        vm.expectRevert(VestingWallet.NothingToRelease.selector);
        v.release();
    }

    /// Anyone may pay the gas; the destination is fixed at construction, so a
    /// third party calling release() can only benefit the beneficiary.
    function test_anyone_may_trigger_release_but_funds_go_to_beneficiary() public {
        vm.warp(start + DURATION);
        vm.prank(makeAddr("stranger"));
        v.release();
        assertEq(beneficiary.balance, AMOUNT);
    }

    /// A cliff beyond the end would vest everything in one step — a time lock
    /// wearing a vesting contract's name, and almost always a typo.
    function test_rejects_cliff_past_duration() public {
        vm.expectRevert(VestingWallet.BadSchedule.selector);
        new VestingWallet(beneficiary, start, DURATION + 1, DURATION);
    }

    function testFuzz_never_releases_more_than_total(uint64 t) public {
        t = uint64(bound(t, start, start + DURATION * 2));
        vm.warp(t);
        assertLe(v.vestedAmount(t), AMOUNT, "vested exceeded the allocation");
    }
}

contract MultisigTest is Test {
    address a = makeAddr("ownerA");
    address b = makeAddr("ownerB");
    address c = makeAddr("ownerC");
    address outsider = makeAddr("outsider");
    address payee = makeAddr("payee");
    Multisig m;

    function setUp() public {
        address[] memory owners = new address[](3);
        owners[0] = a; owners[1] = b; owners[2] = c;
        m = new Multisig{ value: 100 ether }(owners, 2);
    }

    function test_one_confirmation_is_not_enough() public {
        vm.prank(a);
        uint256 id = m.submit(payee, 10 ether, "");
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(Multisig.BelowThreshold.selector, 1, 2));
        m.execute(id);
    }

    function test_threshold_reached_executes() public {
        vm.prank(a);
        uint256 id = m.submit(payee, 10 ether, "");
        vm.prank(b);
        m.confirm(id);
        vm.prank(b);
        m.execute(id);
        assertEq(payee.balance, 10 ether);
    }

    function test_outsider_can_do_nothing() public {
        vm.prank(a);
        uint256 id = m.submit(payee, 1 ether, "");
        vm.startPrank(outsider);
        vm.expectRevert(Multisig.NotOwner.selector);
        m.submit(payee, 1 ether, "");
        vm.expectRevert(Multisig.NotOwner.selector);
        m.confirm(id);
        vm.expectRevert(Multisig.NotOwner.selector);
        m.execute(id);
        vm.stopPrank();
    }

    function test_cannot_confirm_twice() public {
        vm.startPrank(a);
        uint256 id = m.submit(payee, 1 ether, "");
        vm.expectRevert(Multisig.AlreadyConfirmed.selector);
        m.confirm(id);
        vm.stopPrank();
    }

    function test_revoke_drops_below_threshold_again() public {
        vm.prank(a);
        uint256 id = m.submit(payee, 1 ether, "");
        vm.prank(b);
        m.confirm(id);
        vm.prank(b);
        m.revoke(id);
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(Multisig.BelowThreshold.selector, 1, 2));
        m.execute(id);
    }

    function test_cannot_execute_twice() public {
        vm.prank(a);
        uint256 id = m.submit(payee, 1 ether, "");
        vm.prank(b);
        m.confirm(id);
        vm.prank(a);
        m.execute(id);
        vm.prank(a);
        vm.expectRevert(Multisig.AlreadyExecuted.selector);
        m.execute(id);
    }

    /// An owner who could unilaterally add owners would make the threshold
    /// decorative, so owner changes require the same quorum as spending.
    function test_owner_cannot_unilaterally_change_owners() public {
        address[] memory attacker = new address[](1);
        attacker[0] = outsider;
        vm.prank(a);
        vm.expectRevert(Multisig.NotSelf.selector);
        m.setOwners(attacker, 1);
    }

    function test_owner_change_through_quorum_works() public {
        address[] memory next = new address[](2);
        next[0] = a; next[1] = b;
        bytes memory data = abi.encodeCall(Multisig.setOwners, (next, 2));
        vm.prank(a);
        uint256 id = m.submit(address(m), 0, data);
        vm.prank(b);
        m.confirm(id);
        vm.prank(a);
        m.execute(id);
        assertEq(m.ownerCount(), 2);
        assertFalse(m.isOwner(c), "removed owner still authorised");
    }

    /// A duplicate owner would inflate the count without adding a signer, quietly
    /// weakening the threshold it is measured against.
    function test_rejects_duplicate_or_zero_owner() public {
        address[] memory dup = new address[](2);
        dup[0] = a; dup[1] = a;
        vm.expectRevert(Multisig.BadOwnerSet.selector);
        new Multisig(dup, 2);

        address[] memory zero = new address[](2);
        zero[0] = a; zero[1] = address(0);
        vm.expectRevert(Multisig.BadOwnerSet.selector);
        new Multisig(zero, 2);
    }

    function test_threshold_cannot_exceed_owner_count() public {
        address[] memory one = new address[](1);
        one[0] = a;
        vm.expectRevert(Multisig.BadOwnerSet.selector);
        new Multisig(one, 2);
    }
}

contract TimelockTest is Test {
    address proposer = makeAddr("proposer");
    address executor = makeAddr("executor");
    address outsider = makeAddr("outsider");
    address payee = makeAddr("payee");
    Timelock t;
    uint256 constant DELAY = 2 days;

    function setUp() public {
        t = new Timelock{ value: 100 ether }(proposer, executor, DELAY);
    }

    function test_cannot_execute_before_the_delay() public {
        vm.prank(proposer);
        t.queue(payee, 1 ether, "", bytes32(0));
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(Timelock.TooEarly.selector, block.timestamp, block.timestamp + DELAY)
        );
        t.execute(payee, 1 ether, "", bytes32(0));
    }

    function test_executes_after_the_delay() public {
        vm.prank(proposer);
        t.queue(payee, 1 ether, "", bytes32(0));
        vm.warp(block.timestamp + DELAY);
        vm.prank(executor);
        t.execute(payee, 1 ether, "", bytes32(0));
        assertEq(payee.balance, 1 ether);
    }

    /// A forgotten proposal that stayed executable forever would be a latent
    /// authority nobody is tracking.
    function test_expires_after_grace_period() public {
        vm.prank(proposer);
        t.queue(payee, 1 ether, "", bytes32(0));
        uint256 eta = block.timestamp + DELAY;
        // Read GRACE_PERIOD before pranking: vm.prank applies to the NEXT call, and
        // a view call here would consume it, so execute() would arrive unpranked.
        uint256 grace = t.GRACE_PERIOD();
        uint256 deadline = eta + grace;
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(Timelock.Expired.selector, block.timestamp, deadline));
        vm.prank(executor);
        t.execute(payee, 1 ether, "", bytes32(0));
    }

    function test_only_proposer_queues_only_executor_executes() public {
        vm.prank(outsider);
        vm.expectRevert(Timelock.NotProposer.selector);
        t.queue(payee, 1 ether, "", bytes32(0));

        vm.prank(proposer);
        t.queue(payee, 1 ether, "", bytes32(0));
        vm.warp(block.timestamp + DELAY);
        vm.prank(outsider);
        vm.expectRevert(Timelock.NotExecutor.selector);
        t.execute(payee, 1 ether, "", bytes32(0));
    }

    function test_proposer_can_cancel() public {
        vm.startPrank(proposer);
        t.queue(payee, 1 ether, "", bytes32(0));
        t.cancel(payee, 1 ether, "", bytes32(0));
        vm.stopPrank();
        vm.warp(block.timestamp + DELAY);
        vm.prank(executor);
        vm.expectRevert(Timelock.NotQueued.selector);
        t.execute(payee, 1 ether, "", bytes32(0));
    }

    /// If the delay could be set to zero in one step, every guarantee this contract
    /// makes would evaporate exactly when it was needed.
    function test_delay_cannot_be_changed_without_going_through_the_timelock() public {
        vm.prank(proposer);
        vm.expectRevert(Timelock.NotSelf.selector);
        t.setDelay(0);

        // ...and even through the timelock, an out-of-range delay is refused.
        bytes memory data = abi.encodeCall(Timelock.setDelay, (0));
        vm.prank(proposer);
        t.queue(address(t), 0, data, bytes32("d"));
        vm.warp(block.timestamp + DELAY);
        vm.prank(executor);
        vm.expectRevert(Timelock.CallFailed.selector);
        t.execute(address(t), 0, data, bytes32("d"));
        assertEq(t.delay(), DELAY, "delay changed");
    }

    function test_constructor_rejects_out_of_range_delay() public {
        vm.expectRevert(Timelock.BadDelay.selector);
        new Timelock(proposer, executor, 1 minutes);
        vm.expectRevert(Timelock.BadDelay.selector);
        new Timelock(proposer, executor, 31 days);
    }

    /// The delay is only meaningful if the action is visible while it waits.
    function test_queued_action_is_publicly_inspectable_before_execution() public {
        vm.prank(proposer);
        bytes32 id = t.queue(payee, 1 ether, "", bytes32(0));
        assertEq(t.queuedAt(id), block.timestamp + DELAY, "eta not published");
        assertFalse(t.isReady(id));
        vm.warp(block.timestamp + DELAY);
        assertTrue(t.isReady(id));
    }
}
