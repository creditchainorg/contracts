// Copyright (c) CreditChain Research Team. All rights reserved.
// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentSpendVault} from "../src/AgentSpendVault.sol";

/// Property-based (invariant) tests for the agent spending vault.
///
/// Example-based tests (`AgentSpendVault.t.sol`) prove specific scenarios.
/// These prove *properties that must hold under any sequence of actions* — the
/// discipline auditors expect of a contract that custodies value. The fuzzer
/// hammers the handler below with thousands of randomized create/fund/spend/
/// revoke/withdraw/warp sequences and checks the invariants after each step.
contract AgentSpendVaultInvariants is Test {
    AgentSpendVault internal vault;
    Handler internal handler;

    function setUp() public {
        vault = new AgentSpendVault();
        handler = new Handler(vault);

        // Only fuzz the state-changing actions, not the view helpers.
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = Handler.createMandate.selector;
        selectors[1] = Handler.fund.selector;
        selectors[2] = Handler.spend.selector;
        selectors[3] = Handler.allow.selector;
        selectors[4] = Handler.revoke.selector;
        selectors[5] = Handler.withdraw.selector;
        selectors[6] = Handler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// THE vault invariant: the contract's CCC balance always equals the sum of
    /// every mandate's tracked balance. No spend, refund, top-up, or revoke can
    /// create or destroy value, and no funds can be stranded outside a mandate.
    function invariant_solvency() public view {
        assertEq(address(vault).balance, handler.sumOfMandateBalances(), "vault insolvent");
    }

    /// No mandate ever spends past its budget ceiling.
    function invariant_spentWithinBudget() public view {
        uint256 n = handler.mandateCount();
        for (uint256 i; i < n; i++) {
            AgentSpendVault.Mandate memory m = vault.mandate(handler.idAt(i));
            if (m.budget != 0) assertLe(m.spent, m.budget, "spent exceeds budget");
        }
    }

    /// A mandate's balance never goes negative and never exceeds what was put in
    /// (budget is a spend ceiling, not a balance ceiling, so we bound by deposits).
    function invariant_perMandateAccounting() public view {
        uint256 n = handler.mandateCount();
        for (uint256 i; i < n; i++) {
            AgentSpendVault.Mandate memory m = vault.mandate(handler.idAt(i));
            // spent + current balance can only have come from deposits into it.
            assertLe(m.spent + m.balance, handler.depositedTo(handler.idAt(i)), "mandate over-accounted");
        }
    }

    /// Global conservation: everything ever deposited is either still in the
    /// vault or has provably left via spend/refund/withdraw.
    function invariant_valueConservation() public view {
        assertEq(
            handler.totalDeposited(),
            address(vault).balance + handler.totalLeft(),
            "value not conserved"
        );
    }
}

/// Bounded random driver. Every action mirrors a real caller (owner funds and
/// revokes; the mandate's agent spends) and tracks ghost totals the invariants
/// check against. Reverts are swallowed — illegal actions *should* be rejected
/// by the vault; the point is that legal sequences keep the invariants true.
contract Handler is Test {
    AgentSpendVault public vault;

    address[] internal owners;
    address[] internal agents;
    address[] internal recipients;

    uint256[] public ids;
    mapping(uint256 => uint256) public depositedTo; // id => cumulative CCC put in

    uint256 public totalDeposited; // all CCC ever sent into the vault
    uint256 public totalLeft;      // all CCC ever sent out (spend + refund + withdraw)

    constructor(AgentSpendVault _vault) {
        vault = _vault;
        owners.push(address(0xA11CE));
        owners.push(address(0xB0B));
        agents.push(address(0xA9E37));
        agents.push(address(0xA9E38));
        recipients.push(address(0xBEEF));
        recipients.push(address(0xCAFE));
        for (uint256 i; i < owners.length; i++) vm.deal(owners[i], 1_000_000 ether);
    }

    function _pick(address[] storage a, uint256 s) internal view returns (address) {
        return a[s % a.length];
    }

    function createMandate(
        uint256 ownerSeed,
        uint256 agentSeed,
        uint256 fundAmt,
        uint256 budget,
        uint256 perTxMax,
        uint256 windowLimit,
        uint64 windowSeconds,
        uint64 expiry,
        bool allowlist
    ) public {
        address owner = _pick(owners, ownerSeed);
        fundAmt = bound(fundAmt, 0, 100 ether);
        if (owner.balance < fundAmt) return;
        budget = bound(budget, 0, 200 ether);
        perTxMax = bound(perTxMax, 0, 100 ether);
        windowLimit = bound(windowLimit, 0, 100 ether);
        windowSeconds = uint64(bound(windowSeconds, 0, 30 days));
        address agent = _pick(agents, agentSeed);

        vm.prank(owner);
        try vault.createMandate{value: fundAmt}(
            agent, budget, perTxMax, windowLimit, windowSeconds, expiry, allowlist
        ) returns (uint256 id) {
            ids.push(id);
            depositedTo[id] += fundAmt;
            totalDeposited += fundAmt;
        } catch {}
    }

    function fund(uint256 idSeed, uint256 amount) public {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        address from = _pick(owners, idSeed);
        amount = bound(amount, 0, 50 ether);
        if (from.balance < amount) return;

        vm.prank(from);
        try vault.fundMandate{value: amount}(id) {
            depositedTo[id] += amount;
            totalDeposited += amount;
        } catch {}
    }

    function spend(uint256 idSeed, uint256 recipientSeed, uint256 amount, bytes32 ref) public {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        AgentSpendVault.Mandate memory m = vault.mandate(id);
        address recipient = _pick(recipients, recipientSeed);
        amount = bound(amount, 0, 100 ether);

        vm.prank(m.agent);
        try vault.spend(id, recipient, amount, ref) {
            totalLeft += amount;
        } catch {}
    }

    function allow(uint256 idSeed, uint256 recipientSeed, bool ok) public {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        AgentSpendVault.Mandate memory m = vault.mandate(id);
        vm.prank(m.owner);
        try vault.allowRecipient(id, _pick(recipients, recipientSeed), ok) {} catch {}
    }

    function revoke(uint256 idSeed) public {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        AgentSpendVault.Mandate memory m = vault.mandate(id);
        uint256 bal = m.balance;
        vm.prank(m.owner);
        try vault.revoke(id) {
            totalLeft += bal; // revoke refunds exactly the unspent balance
        } catch {}
    }

    function withdraw(uint256 idSeed, uint256 amount) public {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        AgentSpendVault.Mandate memory m = vault.mandate(id);
        amount = bound(amount, 0, 100 ether);
        vm.prank(m.owner);
        try vault.withdraw(id, amount) {
            totalLeft += amount;
        } catch {}
    }

    function warp(uint256 secs) public {
        secs = bound(secs, 0, 7 days);
        vm.warp(block.timestamp + secs);
    }

    // ── views the invariants read ────────────────────────────────────────────

    function sumOfMandateBalances() external view returns (uint256 total) {
        for (uint256 i; i < ids.length; i++) {
            total += vault.mandate(ids[i]).balance;
        }
    }

    function mandateCount() external view returns (uint256) {
        return ids.length;
    }

    function idAt(uint256 i) external view returns (uint256) {
        return ids[i];
    }
}
