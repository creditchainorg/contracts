// Copyright (c) CreditChain Research Team. All rights reserved.
// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentSpendVault} from "../src/AgentSpendVault.sol";
import {AgentReputation} from "../src/AgentReputation.sol";

/// Reputation is built against the REAL vault, so these prove the composition:
/// only a mandate's real owner, with real settled spend, can credit its agent,
/// once per mandate.
contract AgentReputationTest is Test {
    AgentSpendVault vault;
    AgentReputation rep;

    address owner = address(0xA11CE);
    address agent = address(0xA9E);
    address merchant = address(0xB0B);

    function setUp() public {
        vault = new AgentSpendVault();
        rep = new AgentReputation(address(vault));
        vm.deal(owner, 100 ether);
    }

    function _mandateWithSpend(uint256 fund, uint256 spend) internal returns (uint256 id) {
        vm.prank(owner);
        id = vault.createMandate{value: fund}(agent, 0, 0, 0, 0, 0, false);
        vm.prank(agent);
        vault.spend(id, merchant, spend, bytes32(0));
    }

    function test_attestBuildsReputationFromRealMandate() public {
        uint256 id = _mandateWithSpend(10 ether, 3 ether);
        vm.prank(owner);
        rep.attestMandate(id);

        AgentReputation.Reputation memory r = rep.reputation(agent);
        assertEq(r.mandatesServed, 1);
        assertEq(r.valueSettled, 3 ether);
        assertEq(rep.score(agent), 100 + 3); // 1*100 + 3 whole CCC
        assertTrue(rep.attestedMandate(id));
    }

    function test_onlyMandateOwnerCanAttest() public {
        uint256 id = _mandateWithSpend(10 ether, 1 ether);
        vm.prank(merchant);
        vm.expectRevert(AgentReputation.NotMandateOwner.selector);
        rep.attestMandate(id);
        vm.prank(agent); // not even the agent
        vm.expectRevert(AgentReputation.NotMandateOwner.selector);
        rep.attestMandate(id);
    }

    function test_cannotDoubleAttest() public {
        uint256 id = _mandateWithSpend(10 ether, 1 ether);
        vm.prank(owner);
        rep.attestMandate(id);
        vm.prank(owner);
        vm.expectRevert(AgentReputation.AlreadyAttested.selector);
        rep.attestMandate(id);
    }

    function test_cannotAttestUnspentMandate() public {
        vm.prank(owner);
        uint256 id = vault.createMandate{value: 5 ether}(agent, 0, 0, 0, 0, 0, false);
        vm.prank(owner);
        vm.expectRevert(AgentReputation.NoSettledSpend.selector);
        rep.attestMandate(id);
    }

    function test_accumulatesAcrossMandates() public {
        uint256 a = _mandateWithSpend(10 ether, 2 ether);
        uint256 b = _mandateWithSpend(10 ether, 5 ether);
        vm.prank(owner);
        rep.attestMandate(a);
        vm.prank(owner);
        rep.attestMandate(b);

        AgentReputation.Reputation memory r = rep.reputation(agent);
        assertEq(r.mandatesServed, 2);
        assertEq(r.valueSettled, 7 ether);
    }

    function test_constructorRejectsZeroVault() public {
        vm.expectRevert(AgentReputation.ZeroVault.selector);
        new AgentReputation(address(0));
    }
}

/// Invariant: an agent's recorded reputation always equals the ground truth of
/// the mandates actually attested — every point is backed by real settled spend,
/// counted exactly once, and reputation never decreases.
contract AgentReputationInvariants is Test {
    AgentSpendVault vault;
    AgentReputation rep;
    RepHandler handler;

    function setUp() public {
        vault = new AgentSpendVault();
        rep = new AgentReputation(address(vault));
        handler = new RepHandler(vault, rep);

        bytes4[] memory sel = new bytes4[](2);
        sel[0] = RepHandler.createAndSpend.selector;
        sel[1] = RepHandler.attest.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    function invariant_reputationMatchesAttestedTruth() public view {
        AgentReputation.Reputation memory r = rep.reputation(handler.agent());
        assertEq(r.valueSettled, handler.ghostAttestedValue(), "valueSettled mismatch");
        assertEq(r.mandatesServed, handler.ghostAttestedCount(), "mandatesServed mismatch");
    }

    function invariant_scoreIsMonotonic() public view {
        // score == 100*served + valueSettled/1e18 and both components only grow.
        AgentReputation.Reputation memory r = rep.reputation(handler.agent());
        assertEq(rep.score(handler.agent()), r.mandatesServed * 100 + r.valueSettled / 1e18);
    }
}

contract RepHandler is Test {
    AgentSpendVault public vault;
    AgentReputation public rep;
    address public owner = address(0xA11CE);
    address public agent = address(0xA9E);
    address public merchant = address(0xB0B);

    uint256[] public mandates;
    uint256[] public spends;
    uint256 public ghostAttestedValue;
    uint256 public ghostAttestedCount;

    constructor(AgentSpendVault v, AgentReputation r) {
        vault = v;
        rep = r;
        vm.deal(owner, 1_000_000 ether);
    }

    function createAndSpend(uint256 fund, uint256 spend) public {
        fund = bound(fund, 1, 1000 ether);
        if (owner.balance < fund) return;
        spend = bound(spend, 0, fund);
        vm.prank(owner);
        uint256 id = vault.createMandate{value: fund}(agent, 0, 0, 0, 0, 0, false);
        if (spend > 0) {
            vm.prank(agent);
            vault.spend(id, merchant, spend, bytes32(0));
        }
        mandates.push(id);
        spends.push(spend);
    }

    function attest(uint256 idx) public {
        if (mandates.length == 0) return;
        uint256 i = idx % mandates.length;
        uint256 id = mandates[i];
        if (rep.attestedMandate(id) || spends[i] == 0) return;
        vm.prank(owner);
        rep.attestMandate(id);
        ghostAttestedValue += spends[i];
        ghostAttestedCount += 1;
    }
}
