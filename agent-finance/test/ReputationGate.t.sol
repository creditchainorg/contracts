// Copyright (c) CreditChain Research Team. All rights reserved.
// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentSpendVault} from "../src/AgentSpendVault.sol";
import {AgentReputation} from "../src/AgentReputation.sol";
import {ReputationGate} from "../src/ReputationGate.sol";

/// Proves reputation-gated spending against the REAL vault and REAL reputation
/// registry — an agent must earn its score before it can spend, the vault's own
/// rails still bind underneath, and the owner keeps every kill switch.
contract ReputationGateTest is Test {
    AgentSpendVault vault;
    AgentReputation rep;
    ReputationGate gate;

    address owner = address(0xA11CE);
    address operator = address(0xA9E);      // the "real" agent
    address merchant = address(0xB0B);
    address stranger = address(0xC0);

    function setUp() public {
        vault = new AgentSpendVault();
        rep = new AgentReputation(address(vault));
        gate = new ReputationGate(address(vault), address(rep));
        vm.deal(owner, 100 ether);
    }

    /// Mandate whose agent is the gate itself.
    function _gatedMandate(uint256 fund, uint256 perTxMax) internal returns (uint256 id) {
        vm.prank(owner);
        id = vault.createMandate{value: fund}(address(gate), 0, perTxMax, 0, 0, 0, false);
    }

    /// Give `operator` real reputation the only way possible: serve a mandate.
    function _earnReputation(uint256 spendAmount) internal {
        vm.prank(owner);
        uint256 id = vault.createMandate{value: spendAmount}(operator, 0, 0, 0, 0, 0, false);
        vm.prank(operator);
        vault.spend(id, merchant, spendAmount, bytes32(0));
        vm.prank(owner);
        rep.attestMandate(id); // score becomes 100 + whole CCC settled
    }

    function test_unprovenAgentCannotSpend() public {
        uint256 id = _gatedMandate(10 ether, 0);
        vm.prank(owner);
        gate.setPolicy(id, operator, 100); // must have served ≥1 mandate

        assertEq(rep.score(operator), 0, "starts unproven");
        assertFalse(gate.isEligible(id, operator));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ReputationGate.InsufficientReputation.selector, 0, 100));
        gate.spendVia(id, merchant, 1 ether, bytes32(0));
    }

    function test_provenAgentCanSpend() public {
        _earnReputation(3 ether); // score = 100 + 3
        uint256 id = _gatedMandate(10 ether, 0);
        vm.prank(owner);
        gate.setPolicy(id, operator, 100);

        assertTrue(gate.isEligible(id, operator));
        uint256 before = merchant.balance;
        vm.prank(operator);
        gate.spendVia(id, merchant, 2 ether, keccak256("task"));
        assertEq(merchant.balance, before + 2 ether, "gated spend settled");
    }

    /// The gate adds a precondition; it must not weaken the vault's rails.
    function test_vaultRailsStillBindThroughGate() public {
        _earnReputation(3 ether);
        uint256 id = _gatedMandate(10 ether, 1 ether); // per-tx cap 1 CCC
        vm.prank(owner);
        gate.setPolicy(id, operator, 100);

        vm.prank(operator);
        vm.expectRevert(AgentSpendVault.PerTxExceeded.selector);
        gate.spendVia(id, merchant, 2 ether, bytes32(0));
    }

    function test_ownerCanRaiseBarAndCutOffSpending() public {
        _earnReputation(3 ether); // score 103
        uint256 id = _gatedMandate(10 ether, 0);
        vm.prank(owner);
        gate.setPolicy(id, operator, 100);
        vm.prank(operator);
        gate.spendVia(id, merchant, 1 ether, bytes32(0)); // allowed

        vm.prank(owner);
        gate.setPolicy(id, operator, 1_000); // raise the bar immediately
        assertFalse(gate.isEligible(id, operator));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ReputationGate.InsufficientReputation.selector, 103, 1_000));
        gate.spendVia(id, merchant, 1 ether, bytes32(0));
    }

    function test_onlyOperatorAndOnlyOwnerControls() public {
        _earnReputation(3 ether);
        uint256 id = _gatedMandate(10 ether, 0);
        vm.prank(stranger);
        vm.expectRevert(ReputationGate.NotMandateOwner.selector);
        gate.setPolicy(id, operator, 100);

        vm.prank(owner);
        gate.setPolicy(id, operator, 100);
        vm.prank(stranger);
        vm.expectRevert(ReputationGate.NotOperator.selector);
        gate.spendVia(id, merchant, 1 ether, bytes32(0));

        vm.prank(stranger);
        vm.expectRevert(ReputationGate.NotMandateOwner.selector);
        gate.disablePolicy(id);
    }

    function test_disableStopsSpendingAndVaultRevokeStillWorks() public {
        _earnReputation(3 ether);
        uint256 id = _gatedMandate(10 ether, 0);
        vm.prank(owner);
        gate.setPolicy(id, operator, 100);

        vm.prank(owner);
        gate.disablePolicy(id);
        vm.prank(operator);
        vm.expectRevert(ReputationGate.PolicyNotEnabled.selector);
        gate.spendVia(id, merchant, 1 ether, bytes32(0));

        // the vault owner's kill switch is unaffected and refunds
        uint256 ownerBefore = owner.balance;
        vm.prank(owner);
        vault.revoke(id);
        assertEq(owner.balance, ownerBefore + 10 ether, "unspent refunded");
    }

    /// A policy on a mandate the gate does not control would be unenforceable —
    /// reject it rather than record something misleading on-chain.
    function test_rejectsPolicyWhenGateIsNotTheAgent() public {
        vm.prank(owner);
        uint256 id = vault.createMandate{value: 1 ether}(operator, 0, 0, 0, 0, 0, false);
        vm.prank(owner);
        vm.expectRevert(ReputationGate.GateNotMandateAgent.selector);
        gate.setPolicy(id, operator, 100);
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(ReputationGate.ZeroAddress.selector);
        new ReputationGate(address(0), address(rep));
        vm.expectRevert(ReputationGate.ZeroAddress.selector);
        new ReputationGate(address(vault), address(0));
    }
}
