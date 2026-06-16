// Copyright (c) CreditChain Research Team. All rights reserved.
// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentSpendVault} from "../src/AgentSpendVault.sol";

/// Proves every enforced rail of the agent spending mandate. If any guard is
/// weakened, one of these fails — the same golden-test discipline the wallet
/// signers use, applied to the chain's agent-finance primitive.
contract AgentSpendVaultTest is Test {
    AgentSpendVault vault;

    address owner = address(0xAA);
    address agent = address(0xA9);
    address merchant = address(0xB0);
    address stranger = address(0xC0);

    function setUp() public {
        vault = new AgentSpendVault();
        vm.deal(owner, 100 ether);
        vm.deal(agent, 1 ether); // gas only; the agent never spends its own funds
    }

    function _openMandate(
        uint256 fund,
        uint256 budget,
        uint256 perTxMax,
        uint256 windowLimit,
        uint64 windowSeconds,
        uint64 expiry,
        bool allowlist
    ) internal returns (uint256 id) {
        vm.prank(owner);
        id = vault.createMandate{value: fund}(agent, budget, perTxMax, windowLimit, windowSeconds, expiry, allowlist);
    }

    function test_happyPath_agentPaysWithinRails() public {
        uint256 id = _openMandate(10 ether, 10 ether, 5 ether, 0, 0, 0, false);
        uint256 before = merchant.balance;

        vm.prank(agent);
        vault.spend(id, merchant, 3 ether, keccak256("invoice-1"));

        assertEq(merchant.balance, before + 3 ether, "merchant paid");
        AgentSpendVault.Mandate memory m = vault.mandate(id);
        assertEq(m.spent, 3 ether);
        assertEq(m.balance, 7 ether);
    }

    function test_onlyAgentCanSpend() public {
        uint256 id = _openMandate(10 ether, 10 ether, 0, 0, 0, 0, false);
        vm.prank(stranger);
        vm.expectRevert(AgentSpendVault.NotAgent.selector);
        vault.spend(id, merchant, 1 ether, bytes32(0));
        // owner is not the agent either
        vm.prank(owner);
        vm.expectRevert(AgentSpendVault.NotAgent.selector);
        vault.spend(id, merchant, 1 ether, bytes32(0));
    }

    function test_budgetCapEnforced() public {
        uint256 id = _openMandate(10 ether, 4 ether, 0, 0, 0, 0, false);
        vm.prank(agent);
        vault.spend(id, merchant, 4 ether, bytes32(0)); // exactly the budget
        vm.prank(agent);
        vm.expectRevert(AgentSpendVault.BudgetExceeded.selector);
        vault.spend(id, merchant, 1, bytes32(0));
    }

    function test_perTxCapEnforced() public {
        uint256 id = _openMandate(10 ether, 10 ether, 2 ether, 0, 0, 0, false);
        vm.prank(agent);
        vm.expectRevert(AgentSpendVault.PerTxExceeded.selector);
        vault.spend(id, merchant, 2 ether + 1, bytes32(0));
        // at the cap is fine
        vm.prank(agent);
        vault.spend(id, merchant, 2 ether, bytes32(0));
    }

    function test_rollingWindowLimitAndReset() public {
        // 3 CCC per 1-hour window, no other caps.
        uint256 id = _openMandate(10 ether, 0, 0, 3 ether, 3600, 0, false);
        vm.prank(agent);
        vault.spend(id, merchant, 3 ether, bytes32(0)); // fills the window
        vm.prank(agent);
        vm.expectRevert(AgentSpendVault.WindowExceeded.selector);
        vault.spend(id, merchant, 1, bytes32(0));

        // After the window elapses, the agent can spend again.
        vm.warp(block.timestamp + 3601);
        vm.prank(agent);
        vault.spend(id, merchant, 3 ether, bytes32(0));
        AgentSpendVault.Mandate memory m = vault.mandate(id);
        assertEq(m.spent, 6 ether);
    }

    function test_allowlistEnforced() public {
        uint256 id = _openMandate(10 ether, 10 ether, 0, 0, 0, 0, true);
        vm.prank(agent);
        vm.expectRevert(AgentSpendVault.RecipientNotAllowed.selector);
        vault.spend(id, merchant, 1 ether, bytes32(0));

        vm.prank(owner);
        vault.allowRecipient(id, merchant, true);
        vm.prank(agent);
        vault.spend(id, merchant, 1 ether, bytes32(0));
        assertEq(merchant.balance, 1 ether);

        // a non-owner cannot manage the allowlist
        vm.prank(stranger);
        vm.expectRevert(AgentSpendVault.NotOwner.selector);
        vault.allowRecipient(id, stranger, true);
    }

    function test_expiryStopsSpending() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 id = _openMandate(10 ether, 10 ether, 0, 0, 0, exp, false);
        vm.warp(uint256(exp) + 1);
        vm.prank(agent);
        vm.expectRevert(AgentSpendVault.MandateInactive.selector);
        vault.spend(id, merchant, 1 ether, bytes32(0));
    }

    function test_revokeRefundsOwnerAndStopsAgent() public {
        uint256 id = _openMandate(10 ether, 10 ether, 0, 0, 0, 0, false);
        vm.prank(agent);
        vault.spend(id, merchant, 4 ether, bytes32(0));

        uint256 ownerBefore = owner.balance;
        vm.prank(owner);
        vault.revoke(id); // refunds the remaining 6 CCC
        assertEq(owner.balance, ownerBefore + 6 ether, "unspent refunded");

        vm.prank(agent);
        vm.expectRevert(AgentSpendVault.MandateInactive.selector);
        vault.spend(id, merchant, 1, bytes32(0));
    }

    function test_ownerWithdrawUnspent() public {
        uint256 id = _openMandate(10 ether, 10 ether, 0, 0, 0, 0, false);
        uint256 ownerBefore = owner.balance;
        vm.prank(owner);
        vault.withdraw(id, 2 ether);
        assertEq(owner.balance, ownerBefore + 2 ether);
        AgentSpendVault.Mandate memory m = vault.mandate(id);
        assertEq(m.balance, 8 ether);
    }

    function test_insufficientBalanceReverts() public {
        // budget allows 10 but only 1 CCC is funded.
        uint256 id = _openMandate(1 ether, 10 ether, 0, 0, 0, 0, false);
        vm.prank(agent);
        vm.expectRevert(AgentSpendVault.InsufficientBalance.selector);
        vault.spend(id, merchant, 2 ether, bytes32(0));
    }

    function test_anyoneCanTopUp() public {
        uint256 id = _openMandate(1 ether, 10 ether, 0, 0, 0, 0, false);
        vm.deal(stranger, 5 ether);
        vm.prank(stranger);
        vault.fundMandate{value: 5 ether}(id);
        AgentSpendVault.Mandate memory m = vault.mandate(id);
        assertEq(m.balance, 6 ether);
    }

    function test_spendableNow_reflectsTightestRail() public {
        // budget 5, per-tx 2, window 3 → tightest is per-tx (2).
        uint256 id = _openMandate(10 ether, 5 ether, 2 ether, 3 ether, 3600, 0, false);
        assertEq(vault.spendableNow(id), 2 ether);
    }

    /// A malicious recipient that re-enters `spend` must not drain the vault.
    function test_reentrancyResisted() public {
        Reentrant attacker = new Reentrant(vault);
        uint256 id = _openMandate(10 ether, 10 ether, 0, 0, 0, 0, false);
        // make the attacker the agent so it can call spend
        vm.prank(owner);
        uint256 id2 = vault.createMandate{value: 10 ether}(address(attacker), 10 ether, 0, 0, 0, 0, false);
        attacker.setMandate(id2);
        vm.expectRevert(); // reentrant call bubbles up as a failed transfer/guard
        attacker.attack(merchant, 1 ether);
        id; // silence unused
    }
}

/// Tries to re-enter `spend` from its receive hook.
contract Reentrant {
    AgentSpendVault public vault;
    uint256 public mandateId;
    address public target;

    constructor(AgentSpendVault v) {
        vault = v;
    }

    function setMandate(uint256 id) external {
        mandateId = id;
    }

    function attack(address t, uint256 amount) external {
        target = t;
        vault.spend(mandateId, address(this), amount, bytes32(0));
    }

    receive() external payable {
        // attempt to re-enter — the guard must block this
        vault.spend(mandateId, target, 1, bytes32(0));
    }
}
