// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AgentClearing } from "../src/AgentClearing.sol";

/// Drives the clearing contract through random sequences of the operations a
/// real deployment sees, so the invariants below are checked against states no
/// hand-written test would think to construct.
contract ClearingHandler is Test {
    AgentClearing public clearing;

    uint256[] public payerKeys;
    address[] public payers;
    address[] public payees;
    uint256[] public channels;

    /// Mirrors the contract's own accounting so a divergence shows up as a
    /// failed invariant rather than as a silently wrong balance.
    uint256 public totalDeposited;
    uint256 public totalWithdrawn;

    constructor(AgentClearing c) {
        clearing = c;
        for (uint256 i = 1; i <= 3; ++i) {
            payerKeys.push(i * 0x1111);
            address p = vm.addr(i * 0x1111);
            payers.push(p);
            vm.deal(p, 1_000 ether);
        }
        payees.push(address(0xE1));
        payees.push(address(0xE2));
    }

    function deposit(uint256 who, uint96 amount) public {
        address p = payers[who % payers.length];
        amount = uint96(bound(amount, 1, 10 ether));
        vm.prank(p);
        clearing.deposit{ value: amount }();
        totalDeposited += amount;
    }

    function openChannel(uint256 who, uint256 to, uint96 commit, uint96 extraCap) public {
        address p = payers[who % payers.length];
        uint256 free = clearing.available(p);
        if (free == 0) return;
        commit = uint96(bound(commit, 1, free));
        // Cap at or above commit; the excess is the credit case.
        uint256 cap = uint256(commit) + bound(extraCap, 0, 5 ether);
        vm.prank(p);
        uint256 id = clearing.openChannel(
            payees[to % payees.length], commit, cap, uint64(block.timestamp + 30 days)
        );
        channels.push(id);
    }

    function redeem(uint256 idx, uint96 cumulative) public {
        if (channels.length == 0) return;
        uint256 id = channels[idx % channels.length];
        AgentClearing.Channel memory ch = clearing.channel(id);
        if (!ch.open || block.timestamp >= ch.expiry) return;

        cumulative = uint96(bound(cumulative, 1, ch.cap));
        uint256 key = _keyFor(ch.payer);
        if (key == 0) return;

        bytes32 digest = clearing.voucherDigest(id, cumulative);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);

        vm.prank(ch.payee);
        try clearing.redeem(id, cumulative, abi.encodePacked(r, s, v)) { } catch { }
    }

    function withdraw(uint256 who, uint96 amount) public {
        address p = payers[who % payers.length];
        uint256 free = clearing.available(p);
        if (free == 0) return;
        amount = uint96(bound(amount, 1, free));
        vm.prank(p);
        clearing.withdraw(amount);
        totalWithdrawn += amount;
    }

    function withdrawPayee(uint256 who) public {
        address p = payees[who % payees.length];
        uint256 free = clearing.available(p);
        if (free == 0) return;
        vm.prank(p);
        clearing.withdraw(free);
        totalWithdrawn += free;
    }

    function closeChannel(uint256 idx, uint32 skip) public {
        if (channels.length == 0) return;
        uint256 id = channels[idx % channels.length];
        AgentClearing.Channel memory ch = clearing.channel(id);
        if (!ch.open) return;

        vm.prank(ch.payer);
        clearing.startClose(id);
        vm.warp(block.timestamp + clearing.CLOSE_WINDOW() + bound(skip, 1, 1000));
        try clearing.closeChannel(id) { } catch { }
    }

    function _keyFor(address who) internal view returns (uint256) {
        for (uint256 i = 0; i < payers.length; ++i) {
            if (payers[i] == who) return payerKeys[i];
        }
        return 0;
    }

    function channelsLength() external view returns (uint256) {
        return channels.length;
    }

    function bookedLiabilities() external view returns (uint256 total) {
        for (uint256 i = 0; i < payers.length; ++i) {
            total += clearing.available(payers[i]) + clearing.reserved(payers[i]);
        }
        for (uint256 i = 0; i < payees.length; ++i) {
            total += clearing.available(payees[i]) + clearing.reserved(payees[i]);
        }
    }
}

/// The properties that must hold no matter what sequence of calls occurs.
///
/// Non-vacuity was checked directly: temporary probes asserting "no channel was
/// ever opened / no payee was ever paid / no channel was ever closed" all FAIL
/// against this handler, which is how you know the guards above aren't quietly
/// turning every call into a no-op and making the invariants prove nothing.
contract AgentClearingInvariants is Test {
    AgentClearing internal clearing;
    ClearingHandler internal handler;

    function setUp() public {
        clearing = new AgentClearing();
        handler = new ClearingHandler(clearing);
        targetContract(address(handler));
    }

    /// Solvency. Everything the books say is owed must actually be here.
    /// If this ever fails, somebody's collateral has been double-spent.
    function invariant_contractHoldsWhatItOwes() public view {
        assertGe(
            address(clearing).balance,
            handler.bookedLiabilities(),
            "contract owes more than it holds"
        );
    }

    /// Conservation. Value only enters by deposit and leaves by withdrawal;
    /// channels move it between accounts but never create or destroy it.
    function invariant_valueIsConserved() public view {
        assertEq(
            address(clearing).balance,
            handler.totalDeposited() - handler.totalWithdrawn(),
            "value created or destroyed"
        );
    }

    /// A channel can never pay out more than the collateral committed to it.
    /// This is what stops a credit channel from draining the contract on behalf
    /// of a payee who agreed to carry unsecured exposure.
    function invariant_redeemedNeverExceedsCommitted() public view {
        uint256 n = handler.channelsLength();
        for (uint256 i = 0; i < n; ++i) {
            AgentClearing.Channel memory c = clearing.channel(handler.channels(i));
            assertLe(c.redeemed, c.committed, "channel paid out more than it holds");
            assertLe(c.redeemed, c.cap, "channel paid out beyond its cap");
        }
    }

    /// Reserved collateral is backed one-for-one by open channels. A leak here
    /// would mean an account's funds are locked with nothing to unlock them.
    function invariant_reservedMatchesOpenChannels() public view {
        uint256 n = handler.channelsLength();
        uint256 stillReserved;
        for (uint256 i = 0; i < n; ++i) {
            AgentClearing.Channel memory c = clearing.channel(handler.channels(i));
            if (c.open) stillReserved += c.committed - c.redeemed;
        }

        uint256 booked;
        for (uint256 i = 0; i < 3; ++i) {
            booked += clearing.reserved(handler.payers(i));
        }
        assertEq(booked, stillReserved, "reserved balance drifted from open channels");
    }
}
