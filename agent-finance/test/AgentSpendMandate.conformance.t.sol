// Copyright (c) CreditChain Research Team. All rights reserved.
// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentSpendVault} from "../src/AgentSpendVault.sol";
import {IAgentSpendMandate} from "../src/IAgentSpendMandate.sol";

/// Proves `AgentSpendVault` is a conformant ERC-AGM implementation: the whole
/// lifecycle is exercised *only* through the `IAgentSpendMandate` interface, so
/// every standard selector must dispatch and every standard error type must
/// match what the implementation reverts with. This is the conformance bar a
/// second implementation of the standard would also have to clear.
contract AgentSpendMandateConformanceTest is Test {
    IAgentSpendMandate internal vault; // interact ONLY through the standard

    address internal owner = address(0xA11CE);
    address internal agent = address(0xA9E);
    address internal merchant = address(0xB0B);

    function setUp() public {
        vault = IAgentSpendMandate(address(new AgentSpendVault()));
        vm.deal(owner, 100 ether);
    }

    function test_referenceImplConformsToStandard() public {
        vm.prank(owner);
        uint256 id = vault.createMandate{value: 10 ether}(agent, 5 ether, 2 ether, 0, 0, 0, true);
        assertEq(vault.mandateCount(), id, "mandateCount");

        vm.prank(owner);
        vault.allowRecipient(id, merchant, true);
        assertTrue(vault.allowlisted(id, merchant), "allowlisted");

        // The tightest rail right now is the per-tx cap.
        assertEq(vault.spendableNow(id), 2 ether, "spendableNow");

        vm.prank(agent);
        vault.spend(id, merchant, 2 ether, keccak256("task"));
        assertEq(merchant.balance, 2 ether, "paid");

        IAgentSpendMandate.Mandate memory m = vault.mandate(id);
        assertEq(m.spent, 2 ether, "spent");
        assertEq(m.balance, 8 ether, "balance");

        // A rail violation surfaces through the standard error type.
        vm.prank(agent);
        vm.expectRevert(IAgentSpendMandate.PerTxExceeded.selector);
        vault.spend(id, merchant, 3 ether, bytes32(0));

        vm.prank(owner);
        vault.withdraw(id, 1 ether);

        vm.prank(owner);
        vault.revoke(id);
        vm.prank(agent);
        vm.expectRevert(IAgentSpendMandate.MandateInactive.selector);
        vault.spend(id, merchant, 1, bytes32(0));
    }
}
