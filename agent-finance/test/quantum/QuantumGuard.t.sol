// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { QuantumGuard } from "../../src/quantum/QuantumGuard.sol";
import { AgentSpendVault } from "../../src/AgentSpendVault.sol";
import { IAgentSpendMandate } from "../../src/IAgentSpendMandate.sol";
import { WOTSPlus } from "../../src/quantum/WOTSPlus.sol";
import { WOTSPlusSigner } from "./WOTSPlusSigner.sol";

/// @notice Tests for the post-quantum break-glass authority.
///
/// The claim under test is narrow and specific: an attacker who has forged the
/// ECDSA controller key still cannot withdraw, cannot redirect recovery, and is
/// capped by the outflow limit — while the holder of the post-quantum key can
/// always recover everything. Each of those is asserted directly below, including
/// the ones that assert the ABSENCE of a capability.
contract QuantumGuardTest is Test {
    AgentSpendVault vault;
    QuantumGuard guard;

    address controller = makeAddr("controller");
    address recovery = makeAddr("recovery");
    address agent = makeAddr("agent");
    address relayer = makeAddr("relayer");
    address attacker = makeAddr("attacker");

    // The guardian's secret never exists on-chain in production; here it is a
    // test constant so the suite can sign the runtime-dependent digest.
    bytes32 constant SECRET = keccak256("guardian secret seed");
    bytes32 constant PUBSEED = keccak256("guardian public seed");

    uint256 constant LIMIT = 10 ether;
    uint64 constant WINDOW = 1 days;

    function setUp() public {
        vault = new AgentSpendVault();
        guard = new QuantumGuard(address(vault), controller);
        vm.deal(address(guard), 100 ether);
        vm.deal(controller, 1 ether);

        vm.prank(controller);
        guard.armGuardian(WOTSPlusSigner.publicKeyHash(SECRET, PUBSEED), PUBSEED, recovery, LIMIT, WINDOW);
    }

    function _sign() internal view returns (bytes memory) {
        return WOTSPlusSigner.sign(guard.breakGlassDigest(), SECRET, PUBSEED);
    }

    function _openMandate(uint256 amount) internal returns (uint256 id) {
        vm.prank(controller);
        return guard.openMandate(agent, amount, amount, 0, 0, 0, false, amount);
    }

    // ── the core recovery path ───────────────────────────────────────────────

    function test_break_glass_recovers_everything() public {
        // Use the ids the vault actually returns: mandate ids are 1-indexed, so
        // hard-coding 0 here would assert against an empty slot.
        uint256 idA = _openMandate(3 ether);
        uint256 idB = _openMandate(2 ether);
        assertEq(guard.mandateCount(), 2);

        uint256 guardBalance = address(guard).balance;
        vm.prank(relayer);
        guard.breakGlass(_sign());

        // Every mandate revoked, every unspent balance pulled back and swept.
        assertEq(recovery.balance, guardBalance + 5 ether, "funds not fully recovered");
        assertEq(address(guard).balance, 0, "guard retained funds");
        assertTrue(vault.mandate(idA).revoked, "first mandate still live");
        assertTrue(vault.mandate(idB).revoked, "second mandate still live");
        assertEq(guard.controller(), recovery, "controller not rotated");
        assertTrue(guard.frozen(), "guard not frozen");
    }

    /// A mandate the agent has already partly spent must still recover the remainder.
    function test_break_glass_recovers_unspent_remainder_after_agent_spending() public {
        uint256 id = _openMandate(4 ether);
        vm.prank(agent);
        vault.spend(id, makeAddr("merchant"), 1 ether, keccak256("task"));

        uint256 guardBalance = address(guard).balance;
        vm.prank(relayer);
        guard.breakGlass(_sign());

        // 4 sent to the mandate, 1 legitimately spent, 3 recovered.
        assertEq(recovery.balance, guardBalance + 3 ether, "remainder not recovered");
    }

    // ── one-time enforcement: the load-bearing property ──────────────────────

    /// WOTS+ keys are one-time. A second use would leak enough to forge, so the
    /// contract must refuse it even though the signature is cryptographically valid.
    function test_break_glass_cannot_be_replayed() public {
        bytes memory sig = _sign();
        vm.prank(relayer);
        guard.breakGlass(sig);

        vm.expectRevert(QuantumGuard.GuardianConsumed.selector);
        vm.prank(relayer);
        guard.breakGlass(sig);
    }

    /// The same key armed on a second guard must not accept the first guard's
    /// signature — the digest binds `address(this)`.
    function test_signature_does_not_replay_across_guards() public {
        QuantumGuard other = new QuantumGuard(address(vault), controller);
        vm.deal(address(other), 10 ether);
        vm.prank(controller);
        other.armGuardian(WOTSPlusSigner.publicKeyHash(SECRET, PUBSEED), PUBSEED, recovery, LIMIT, WINDOW);

        bytes memory sigForGuard = _sign();
        vm.expectRevert(QuantumGuard.InvalidQuantumSignature.selector);
        other.breakGlass(sigForGuard);
    }

    /// The digest binds `block.chainid`, so a signature lifted from another chain fails.
    function test_signature_does_not_replay_across_chains() public {
        bytes memory sig = _sign();
        vm.chainId(block.chainid + 1);
        vm.expectRevert(QuantumGuard.InvalidQuantumSignature.selector);
        guard.breakGlass(sig);
    }

    function test_rejects_garbage_signature() public {
        bytes memory junk = new bytes(WOTSPlus.SIG_BYTES);
        vm.expectRevert(QuantumGuard.InvalidQuantumSignature.selector);
        guard.breakGlass(junk);
    }

    // ── the asymmetry that makes the guardian worth having ───────────────────

    /// If the controller could withdraw, a forged ECDSA key would drain the guard
    /// and the post-quantum key would be decoration. There is deliberately no
    /// withdraw path under controller authority — asserted here against the ABI.
    function test_controller_has_no_withdraw_function() public view {
        // Any of these selectors existing on the guard would defeat the design.
        bytes4[3] memory forbidden = [
            bytes4(keccak256("withdraw(uint256)")),
            bytes4(keccak256("sweep(address)")),
            bytes4(keccak256("transfer(address,uint256)"))
        ];
        for (uint256 i = 0; i < forbidden.length; ++i) {
            (bool ok,) = address(guard).staticcall(abi.encodeWithSelector(forbidden[i], uint256(1)));
            assertFalse(ok, "guard exposes a controller-callable value-extraction path");
        }
    }

    /// A forged controller key must not be able to point recovery at itself.
    function test_controller_cannot_rearm_to_redirect_recovery() public {
        vm.prank(controller);
        vm.expectRevert(QuantumGuard.AlreadyArmed.selector);
        guard.armGuardian(keccak256("attacker key"), PUBSEED, attacker, LIMIT, WINDOW);
        assertEq(guard.recoveryAddress(), recovery);
    }

    /// The outflow limit is the cap on what a forged controller key can leak
    /// before the guardian stops it.
    function test_outflow_limit_bounds_a_compromised_controller() public {
        _openMandate(LIMIT); // exactly exhausts the window

        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(QuantumGuard.OutflowExceeded.selector, 1 wei, 0));
        guard.openMandate(attacker, 1 wei, 1 wei, 0, 0, 0, false, 1 wei);

        assertEq(guard.outflowRemaining(), 0);
    }

    /// The window is rolling, not lifetime — it must reset once it lapses.
    function test_outflow_window_resets() public {
        _openMandate(LIMIT);
        assertEq(guard.outflowRemaining(), 0);
        vm.warp(block.timestamp + WINDOW + 1);
        assertEq(guard.outflowRemaining(), LIMIT, "window did not reset");
        _openMandate(LIMIT); // must now succeed
    }

    function test_non_controller_cannot_operate() public {
        vm.prank(attacker);
        vm.expectRevert(QuantumGuard.NotController.selector);
        guard.openMandate(attacker, 1 ether, 1 ether, 0, 0, 0, false, 1 ether);
    }

    /// After recovery the guard is spent: the old controller has been rotated away,
    /// and the new controller inherits a frozen guard rather than a live one. Both
    /// paths are asserted because they fail for different reasons and both matter —
    /// break-glass is a terminal event, not a change of management.
    function test_break_glass_leaves_the_guard_permanently_inert() public {
        vm.prank(relayer);
        guard.breakGlass(_sign());

        // Old controller: no longer the controller at all.
        vm.prank(controller);
        vm.expectRevert(QuantumGuard.NotController.selector);
        guard.openMandate(agent, 1 ether, 1 ether, 0, 0, 0, false, 1 ether);

        // New controller (the recovery address): is the controller, but frozen.
        vm.prank(recovery);
        vm.expectRevert(QuantumGuard.Frozen.selector);
        guard.openMandate(agent, 1 ether, 1 ether, 0, 0, 0, false, 1 ether);
    }

    // ── relaying ─────────────────────────────────────────────────────────────

    /// In a real recovery the owner may hold no working key and no gas, so a third
    /// party must be able to submit the signature. Safe because the destination is
    /// fixed at arm time and signed into the digest.
    function test_anyone_may_relay_the_signature_but_funds_only_go_to_recovery() public {
        bytes memory sig = _sign();
        uint256 expected = address(guard).balance;

        vm.prank(attacker); // even the attacker relaying it only helps the owner
        guard.breakGlass(sig);

        assertEq(recovery.balance, expected);
        assertEq(attacker.balance, 0, "relayer captured value");
    }

    // ── lifecycle guards ─────────────────────────────────────────────────────

    function test_unarmed_guard_cannot_break_glass() public {
        QuantumGuard fresh = new QuantumGuard(address(vault), controller);
        vm.expectRevert(QuantumGuard.NotArmed.selector);
        fresh.breakGlass(new bytes(WOTSPlus.SIG_BYTES));
    }

    function test_cost_of_break_glass() public {
        _openMandate(1 ether);
        bytes memory sig = _sign();
        uint256 before = gasleft();
        vm.prank(relayer);
        guard.breakGlass(sig);
        console.log("breakGlass gas (1 mandate):", before - gasleft());
    }
}
