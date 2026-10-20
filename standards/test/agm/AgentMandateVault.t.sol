// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { AgentMandateVault } from "../../src/agm/AgentMandateVault.sol";
import { IAgentMandateVault } from "../../src/agm/IAgentMandateVault.sol";
import { AssetTransfer } from "../../src/lib/AssetTransfer.sol";
import {
    MockERC20,
    NoReturnERC20,
    FalseReturnERC20,
    FeeOnTransferERC20
} from "../mocks/Tokens.sol";
import { Erc1271Agent, ReentrantRecipient, RejectingRecipient } from "../mocks/Actors.sol";

contract AgentMandateVaultTest is Test {
    AgentMandateVault vault;
    MockERC20 usdc;

    address owner = makeAddr("owner");
    address shop = makeAddr("shop");
    address relayer = makeAddr("relayer");
    uint256 agentKey = 0xA11CE;
    address agent;

    function setUp() public {
        vault = new AgentMandateVault();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        agent = vm.addr(agentKey);
        vm.deal(owner, 1000 ether);
        usdc.mint(owner, 1_000_000e6);
        vm.prank(owner);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _terms(address asset, uint256 amount)
        internal
        view
        returns (IAgentMandateVault.MandateTerms memory t)
    {
        t.agent = agent;
        t.asset = asset;
        t.amount = amount;
    }

    function _native(uint256 amount) internal returns (uint256 id) {
        vm.prank(owner);
        id = vault.createMandate{ value: amount }(_terms(address(0), amount));
    }

    function _create(IAgentMandateVault.MandateTerms memory t) internal returns (uint256 id) {
        vm.prank(owner);
        id = vault.createMandate{ value: t.asset == address(0) ? t.amount : 0 }(t);
    }

    function _auth(uint256 id, uint256 amount, uint256 fee, uint256 nonce)
        internal
        view
        returns (IAgentMandateVault.SpendAuthorization memory a)
    {
        a = IAgentMandateVault.SpendAuthorization({
            mandateId: id,
            recipient: shop,
            amount: amount,
            receipt: keccak256("receipt"),
            fee: fee,
            nonce: nonce,
            deadline: block.timestamp + 1 hours
        });
    }

    function _sign(uint256 key, IAgentMandateVault.SpendAuthorization memory a)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, vault.spendDigest(a));
        return abi.encodePacked(r, s, v);
    }

    // ───────────────────────────── create & fund ─────────────────────────────

    function test_createNative_recordsTermsAndFunds() public {
        IAgentMandateVault.MandateTerms memory t = _terms(address(0), 5 ether);
        t.budget = 4 ether;
        t.perTxMax = 1 ether;
        t.windowLimit = 2 ether;
        t.windowSeconds = 1 days;
        t.expiry = uint64(block.timestamp + 30 days);
        t.allowlistEnabled = true;
        t.maxRelayFee = 0.01 ether;

        vm.expectEmit(true, true, true, true, address(vault));
        emit IAgentMandateVault.MandateCreated(
            1,
            owner,
            agent,
            address(0),
            4 ether,
            1 ether,
            2 ether,
            1 days,
            t.expiry,
            true,
            0.01 ether
        );
        uint256 id = _create(t);

        IAgentMandateVault.Mandate memory m = vault.mandate(id);
        assertEq(id, 1);
        assertEq(m.owner, owner);
        assertEq(m.agent, agent);
        assertEq(m.asset, address(0));
        assertEq(m.balance, 5 ether);
        assertEq(m.budget, 4 ether);
        assertEq(m.perTxMax, 1 ether);
        assertEq(m.windowLimit, 2 ether);
        assertEq(m.windowSeconds, 1 days);
        assertEq(m.expiry, t.expiry);
        assertTrue(m.allowlistEnabled);
        assertEq(m.maxRelayFee, 0.01 ether);
        assertEq(address(vault).balance, 5 ether);
    }

    function test_createErc20_pullsTokens() public {
        uint256 id = _create(_terms(address(usdc), 100e6));
        assertEq(vault.mandate(id).balance, 100e6);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
    }

    function test_create_rejectsWrongValue() public {
        IAgentMandateVault.MandateTerms memory t = _terms(address(0), 1 ether);
        vm.prank(owner);
        vm.expectRevert(IAgentMandateVault.WrongValue.selector);
        vault.createMandate{ value: 0.5 ether }(t);

        t = _terms(address(usdc), 1e6);
        vm.prank(owner);
        vm.expectRevert(IAgentMandateVault.WrongValue.selector);
        vault.createMandate{ value: 1 }(t);
    }

    function test_create_rejectsZeroAgent() public {
        IAgentMandateVault.MandateTerms memory t = _terms(address(0), 0);
        t.agent = address(0);
        vm.prank(owner);
        vm.expectRevert(IAgentMandateVault.ZeroAddress.selector);
        vault.createMandate(t);
    }

    function test_create_rejectsAmountsAboveUint128() public {
        IAgentMandateVault.MandateTerms memory t = _terms(address(0), 0);
        t.budget = uint256(type(uint128).max) + 1;
        vm.prank(owner);
        vm.expectRevert(IAgentMandateVault.AmountTooLarge.selector);
        vault.createMandate(t);
    }

    function test_create_rejectsAddressWithoutCode() public {
        IAgentMandateVault.MandateTerms memory t = _terms(makeAddr("not-a-token"), 1);
        vm.prank(owner);
        vm.expectRevert();
        vault.createMandate(t);
    }

    function test_fund_anyoneCanTopUp() public {
        uint256 id = _native(1 ether);
        address treasury = makeAddr("treasury");
        vm.deal(treasury, 3 ether);
        vm.prank(treasury);
        vault.fund{ value: 3 ether }(id, 3 ether);
        assertEq(vault.mandate(id).balance, 4 ether);
    }

    function test_fund_rejectsRevokedAndMissing() public {
        uint256 id = _native(1 ether);
        vm.prank(owner);
        vault.revoke(id);
        vm.prank(owner);
        vm.expectRevert(IAgentMandateVault.MandateInactive.selector);
        vault.fund{ value: 1 }(id, 1);
        vm.prank(owner);
        vm.expectRevert(IAgentMandateVault.MandateInactive.selector);
        vault.fund{ value: 1 }(99, 1);
    }

    function test_feeOnTransferToken_creditsWhatArrived() public {
        FeeOnTransferERC20 fee = new FeeOnTransferERC20();
        fee.mint(owner, 1000e18);
        vm.prank(owner);
        fee.approve(address(vault), type(uint256).max);
        uint256 id = _create(_terms(address(fee), 100e18));
        assertEq(vault.mandate(id).balance, 99e18);
        assertEq(fee.balanceOf(address(vault)), 99e18);
    }

    function test_noReturnToken_works() public {
        NoReturnERC20 usdt = new NoReturnERC20();
        usdt.mint(owner, 1000e6);
        vm.prank(owner);
        usdt.approve(address(vault), type(uint256).max);
        uint256 id = _create(_terms(address(usdt), 100e6));
        vm.prank(agent);
        vault.spend(id, shop, 40e6, bytes32(0));
        assertEq(usdt.balanceOf(shop), 40e6);
        assertEq(vault.mandate(id).balance, 60e6);
    }

    function test_falseReturningToken_revertsAndMovesNothing() public {
        FalseReturnERC20 t = new FalseReturnERC20();
        t.mint(owner, 100e18);
        vm.prank(owner);
        t.approve(address(vault), type(uint256).max);
        uint256 id = _create(_terms(address(t), 10e18));
        t.setFail(true);
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetTransfer.AssetTransferFailed.selector, address(t), shop, 1e18
            )
        );
        vault.spend(id, shop, 1e18, bytes32(0));
        assertEq(vault.mandate(id).spent, 0);
        assertEq(vault.mandate(id).balance, 10e18);
    }

    // ───────────────────────────── direct spends & rails ─────────────────────────────

    function test_spend_paysAndRecordsReceipt() public {
        uint256 id = _create(_terms(address(usdc), 100e6));
        bytes32 receipt = keccak256("GET /v1/inference model=x tokens=812");
        vm.expectEmit(true, true, true, true, address(vault));
        emit IAgentMandateVault.AgentPayment(id, agent, shop, 3e6, receipt, 3e6);
        vm.prank(agent);
        vault.spend(id, shop, 3e6, receipt);
        assertEq(usdc.balanceOf(shop), 3e6);
        assertEq(vault.mandate(id).spent, 3e6);
        assertEq(vault.mandate(id).balance, 97e6);
    }

    function test_spend_onlyAgent() public {
        uint256 id = _native(1 ether);
        vm.prank(owner);
        vm.expectRevert(IAgentMandateVault.NotAgent.selector);
        vault.spend(id, shop, 1, bytes32(0));
    }

    function test_spend_zeroRecipientAndAmount() public {
        uint256 id = _native(1 ether);
        vm.startPrank(agent);
        vm.expectRevert(IAgentMandateVault.ZeroAddress.selector);
        vault.spend(id, address(0), 1, bytes32(0));
        vm.expectRevert(IAgentMandateVault.ZeroAmount.selector);
        vault.spend(id, shop, 0, bytes32(0));
        vm.stopPrank();
    }

    function test_rail_perTx() public {
        IAgentMandateVault.MandateTerms memory t = _terms(address(0), 10 ether);
        t.perTxMax = 1 ether;
        uint256 id = _create(t);
        vm.startPrank(agent);
        vault.spend(id, shop, 1 ether, bytes32(0));
        vm.expectRevert(IAgentMandateVault.PerTxExceeded.selector);
        vault.spend(id, shop, 1 ether + 1, bytes32(0));
        vm.stopPrank();
    }

    function test_rail_budget() public {
        IAgentMandateVault.MandateTerms memory t = _terms(address(0), 10 ether);
        t.budget = 3 ether;
        uint256 id = _create(t);
        vm.startPrank(agent);
        vault.spend(id, shop, 2 ether, bytes32(0));
        vm.expectRevert(IAgentMandateVault.BudgetExceeded.selector);
        vault.spend(id, shop, 1 ether + 1, bytes32(0));
        vault.spend(id, shop, 1 ether, bytes32(0));
        vm.stopPrank();
        assertEq(vault.spendableNow(id), 0);
    }

    function test_rail_windowResetsAfterWindow() public {
        IAgentMandateVault.MandateTerms memory t = _terms(address(0), 10 ether);
        t.windowLimit = 1 ether;
        t.windowSeconds = 1 hours;
        uint256 id = _create(t);
        vm.startPrank(agent);
        vault.spend(id, shop, 0.6 ether, bytes32(0));
        vm.expectRevert(IAgentMandateVault.WindowExceeded.selector);
        vault.spend(id, shop, 0.5 ether, bytes32(0));
        vm.warp(block.timestamp + 1 hours);
        vault.spend(id, shop, 1 ether, bytes32(0));
        vm.stopPrank();
    }

    function test_rail_allowlist() public {
        IAgentMandateVault.MandateTerms memory t = _terms(address(0), 1 ether);
        t.allowlistEnabled = true;
        uint256 id = _create(t);
        vm.prank(agent);
        vm.expectRevert(IAgentMandateVault.RecipientNotAllowed.selector);
        vault.spend(id, shop, 1, bytes32(0));
        vm.prank(owner);
        vault.allowRecipient(id, shop, true);
        vm.prank(agent);
        vault.spend(id, shop, 1, bytes32(0));
        vm.prank(shop);
        vm.expectRevert(IAgentMandateVault.NotOwner.selector);
        vault.allowRecipient(id, shop, false);
    }

    function test_rail_expiry() public {
        IAgentMandateVault.MandateTerms memory t = _terms(address(0), 1 ether);
        t.expiry = uint64(block.timestamp + 1 days);
        uint256 id = _create(t);
        vm.warp(t.expiry);
        vm.prank(agent);
        vault.spend(id, shop, 1, bytes32(0)); // still valid at the expiry second
        vm.warp(uint256(t.expiry) + 1);
        vm.prank(agent);
        vm.expectRevert(IAgentMandateVault.MandateInactive.selector);
        vault.spend(id, shop, 1, bytes32(0));
        assertEq(vault.spendableNow(id), 0);
    }

    function test_rail_balance() public {
        uint256 id = _native(1 ether);
        vm.prank(agent);
        vm.expectRevert(IAgentMandateVault.InsufficientBalance.selector);
        vault.spend(id, shop, 1 ether + 1, bytes32(0));
    }

    function test_pause_stopsAndResumes() public {
        uint256 id = _native(1 ether);
        vm.prank(owner);
        vault.setPaused(id, true);
        vm.prank(agent);
        vm.expectRevert(IAgentMandateVault.MandateInactive.selector);
        vault.spend(id, shop, 1, bytes32(0));
        assertEq(vault.spendableNow(id), 0);
        vm.prank(owner);
        vault.setPaused(id, false);
        vm.prank(agent);
        vault.spend(id, shop, 1, bytes32(0));
    }

    function test_spentToOwner_tracksSelfPayment() public {
        uint256 id = _native(2 ether);
        vm.startPrank(agent);
        vault.spend(id, owner, 0.5 ether, bytes32(0));
        vault.spend(id, shop, 0.25 ether, bytes32(0));
        vm.stopPrank();
        IAgentMandateVault.Mandate memory m = vault.mandate(id);
        assertEq(m.spent, 0.75 ether);
        assertEq(m.spentToOwner, 0.5 ether);
    }

    // ───────────────────────────── owner controls ─────────────────────────────

    function test_revoke_refundsAndStopsForever() public {
        uint256 id = _create(_terms(address(usdc), 100e6));
        vm.prank(agent);
        vault.spend(id, shop, 10e6, bytes32(0));
        uint256 before = usdc.balanceOf(owner);
        vm.prank(owner);
        vault.revoke(id);
        assertEq(usdc.balanceOf(owner) - before, 90e6);
        vm.prank(agent);
        vm.expectRevert(IAgentMandateVault.MandateInactive.selector);
        vault.spend(id, shop, 1, bytes32(0));
        vm.prank(owner);
        vm.expectRevert(IAgentMandateVault.MandateInactive.selector);
        vault.setPaused(id, false);
    }

    function test_withdraw_partial() public {
        uint256 id = _native(3 ether);
        uint256 before = owner.balance;
        vm.prank(owner);
        vault.withdraw(id, 1 ether);
        assertEq(owner.balance - before, 1 ether);
        assertEq(vault.mandate(id).balance, 2 ether);
        vm.prank(owner);
        vm.expectRevert(IAgentMandateVault.InsufficientBalance.selector);
        vault.withdraw(id, 2 ether + 1);
        vm.prank(shop);
        vm.expectRevert(IAgentMandateVault.NotOwner.selector);
        vault.withdraw(id, 1);
    }

    function test_onlyOwnerControls() public {
        uint256 id = _native(1 ether);
        vm.startPrank(agent);
        vm.expectRevert(IAgentMandateVault.NotOwner.selector);
        vault.revoke(id);
        vm.expectRevert(IAgentMandateVault.NotOwner.selector);
        vault.setPaused(id, true);
        vm.expectRevert(IAgentMandateVault.NotOwner.selector);
        vault.rotateAgent(id, agent);
        vm.stopPrank();
    }

    // ───────────────────────────── signed spends ─────────────────────────────

    function test_signed_relayerPaysGasAndTakesFee() public {
        IAgentMandateVault.MandateTerms memory t = _terms(address(usdc), 100e6);
        t.maxRelayFee = 0.05e6;
        uint256 id = _create(t);
        IAgentMandateVault.SpendAuthorization memory a = _auth(id, 2e6, 0.02e6, 7);
        bytes memory sig = _sign(agentKey, a);

        vm.prank(relayer);
        vault.spendWithSignature(a, sig);
        assertEq(usdc.balanceOf(shop), 2e6);
        assertEq(usdc.balanceOf(relayer), 0.02e6);
        IAgentMandateVault.Mandate memory m = vault.mandate(id);
        assertEq(m.spent, 2.02e6, "fees count against the budget");
        assertEq(m.balance, 97.98e6);
        assertTrue(vault.nonceUsed(id, 7));
        assertEq(agent.balance, 0, "the agent never needed gas");
    }

    function test_signed_replayRejected() public {
        uint256 id = _create(_terms(address(usdc), 100e6));
        IAgentMandateVault.SpendAuthorization memory a = _auth(id, 1e6, 0, 1);
        bytes memory sig = _sign(agentKey, a);
        vault.spendWithSignature(a, sig);
        vm.expectRevert(IAgentMandateVault.NonceUsed.selector);
        vault.spendWithSignature(a, sig);
    }

    function test_signed_unorderedNonces() public {
        uint256 id = _create(_terms(address(usdc), 100e6));
        IAgentMandateVault.SpendAuthorization memory a9 = _auth(id, 1e6, 0, 9);
        IAgentMandateVault.SpendAuthorization memory a3 = _auth(id, 1e6, 0, 3);
        bytes memory s9 = _sign(agentKey, a9);
        bytes memory s3 = _sign(agentKey, a3);
        vault.spendWithSignature(a9, s9);
        vault.spendWithSignature(a3, s3);
        assertEq(usdc.balanceOf(shop), 2e6);
    }

    function test_signed_deadline() public {
        uint256 id = _create(_terms(address(usdc), 100e6));
        IAgentMandateVault.SpendAuthorization memory a = _auth(id, 1e6, 0, 1);
        bytes memory sig = _sign(agentKey, a);
        vm.warp(a.deadline + 1);
        vm.expectRevert(IAgentMandateVault.SignatureExpired.selector);
        vault.spendWithSignature(a, sig);
    }

    function test_signed_feeAboveCapRejected() public {
        IAgentMandateVault.MandateTerms memory t = _terms(address(usdc), 100e6);
        t.maxRelayFee = 0.01e6;
        uint256 id = _create(t);
        IAgentMandateVault.SpendAuthorization memory a = _auth(id, 1e6, 0.01e6 + 1, 1);
        bytes memory sig = _sign(agentKey, a);
        vm.expectRevert(IAgentMandateVault.FeeExceedsCap.selector);
        vault.spendWithSignature(a, sig);
    }

    function test_signed_zeroCapMeansFreeRelaysOnly() public {
        uint256 id = _create(_terms(address(usdc), 100e6));
        IAgentMandateVault.SpendAuthorization memory free = _auth(id, 1e6, 0, 1);
        vault.spendWithSignature(free, _sign(agentKey, free));
        IAgentMandateVault.SpendAuthorization memory paid = _auth(id, 1e6, 1, 2);
        bytes memory sig = _sign(agentKey, paid);
        vm.expectRevert(IAgentMandateVault.FeeExceedsCap.selector);
        vault.spendWithSignature(paid, sig);
    }

    function test_signed_tamperingBreaksSignature() public {
        uint256 id = _create(_terms(address(usdc), 100e6));
        IAgentMandateVault.SpendAuthorization memory a = _auth(id, 1e6, 0, 1);
        bytes memory sig = _sign(agentKey, a);
        a.recipient = relayer; // a relayer tries to redirect the payment
        vm.expectRevert(IAgentMandateVault.BadSignature.selector);
        vault.spendWithSignature(a, sig);
    }

    function test_signed_wrongSignerRejected() public {
        uint256 id = _create(_terms(address(usdc), 100e6));
        IAgentMandateVault.SpendAuthorization memory a = _auth(id, 1e6, 0, 1);
        bytes memory sig = _sign(0xBAD, a);
        vm.expectRevert(IAgentMandateVault.BadSignature.selector);
        vault.spendWithSignature(a, sig);
    }

    function test_signed_malleableSignatureRejected() public {
        uint256 id = _create(_terms(address(usdc), 100e6));
        IAgentMandateVault.SpendAuthorization memory a = _auth(id, 1e6, 0, 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentKey, vault.spendDigest(a));
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes memory twin =
            abi.encodePacked(r, bytes32(n - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        vm.expectRevert(IAgentMandateVault.BadSignature.selector);
        vault.spendWithSignature(a, twin);
    }

    function test_signed_otherVaultSignatureRejected() public {
        AgentMandateVault other = new AgentMandateVault();
        uint256 id = _create(_terms(address(usdc), 100e6));
        IAgentMandateVault.SpendAuthorization memory a = _auth(id, 1e6, 0, 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentKey, other.spendDigest(a));
        vm.expectRevert(IAgentMandateVault.BadSignature.selector);
        vault.spendWithSignature(a, abi.encodePacked(r, s, v));
    }

    function test_signed_otherChainSignatureRejected() public {
        uint256 id = _create(_terms(address(usdc), 100e6));
        IAgentMandateVault.SpendAuthorization memory a = _auth(id, 1e6, 0, 1);
        bytes memory sig = _sign(agentKey, a);
        vm.chainId(block.chainid + 1);
        vm.expectRevert(IAgentMandateVault.BadSignature.selector);
        vault.spendWithSignature(a, sig);
    }

    function test_signed_rotationInvalidatesOldKey() public {
        uint256 id = _create(_terms(address(usdc), 100e6));
        IAgentMandateVault.SpendAuthorization memory a = _auth(id, 1e6, 0, 1);
        bytes memory oldSig = _sign(agentKey, a);
        uint256 newKey = 0xB0B;
        vm.prank(owner);
        vault.rotateAgent(id, vm.addr(newKey));
        vm.expectRevert(IAgentMandateVault.BadSignature.selector);
        vault.spendWithSignature(a, oldSig);
        vault.spendWithSignature(a, _sign(newKey, a));
        assertEq(usdc.balanceOf(shop), 1e6);
    }

    function test_signed_erc1271Agent() public {
        uint256 signerKey = 0xC0FFEE;
        Erc1271Agent wallet = new Erc1271Agent(vm.addr(signerKey));
        IAgentMandateVault.MandateTerms memory t = _terms(address(usdc), 100e6);
        t.agent = address(wallet);
        uint256 id = _create(t);
        IAgentMandateVault.SpendAuthorization memory a = _auth(id, 4e6, 0, 1);
        vault.spendWithSignature(a, _sign(signerKey, a));
        assertEq(usdc.balanceOf(shop), 4e6);

        IAgentMandateVault.SpendAuthorization memory b = _auth(id, 4e6, 0, 2);
        bytes memory wrong = _sign(agentKey, b); // a key the wallet does not hold
        vm.expectRevert(IAgentMandateVault.BadSignature.selector);
        vault.spendWithSignature(b, wrong);
    }

    function test_signed_railsStillApply() public {
        IAgentMandateVault.MandateTerms memory t = _terms(address(usdc), 100e6);
        t.windowLimit = 5e6;
        t.windowSeconds = 1 days;
        t.maxRelayFee = 1e6;
        uint256 id = _create(t);
        IAgentMandateVault.SpendAuthorization memory a = _auth(id, 4e6, 1e6, 1);
        vault.spendWithSignature(a, _sign(agentKey, a));
        IAgentMandateVault.SpendAuthorization memory b = _auth(id, 1, 0, 2);
        bytes memory sig = _sign(agentKey, b);
        vm.expectRevert(IAgentMandateVault.WindowExceeded.selector);
        vault.spendWithSignature(b, sig);
    }

    function test_signed_unknownMandate() public {
        IAgentMandateVault.SpendAuthorization memory a = _auth(42, 1, 0, 1);
        bytes memory sig = _sign(agentKey, a);
        vm.expectRevert(IAgentMandateVault.MandateInactive.selector);
        vault.spendWithSignature(a, sig);
    }

    // ───────────────────────────── hostile counterparties ─────────────────────────────

    function test_reentrantRecipient_cannotReenter() public {
        ReentrantRecipient bad = new ReentrantRecipient(IAgentMandateVault(address(vault)));
        IAgentMandateVault.MandateTerms memory t = _terms(address(0), 2 ether);
        t.agent = address(bad);
        uint256 id = _create(t);
        for (uint8 mode = 1; mode <= 3; mode++) {
            bad.arm(id, mode);
            vm.prank(address(bad));
            vm.expectRevert(
                abi.encodeWithSelector(
                    AssetTransfer.AssetTransferFailed.selector, address(0), address(bad), 1 ether
                )
            );
            vault.spend(id, address(bad), 1 ether, bytes32(0));
        }
        assertEq(vault.mandate(id).balance, 2 ether);
        assertEq(vault.mandate(id).spent, 0);
    }

    function test_rejectingRecipient_revertsWholeSpend() public {
        RejectingRecipient r = new RejectingRecipient();
        uint256 id = _native(1 ether);
        vm.prank(agent);
        vm.expectRevert();
        vault.spend(id, address(r), 1, bytes32(0));
        assertEq(vault.mandate(id).balance, 1 ether);
    }

    // ───────────────────────────── views ─────────────────────────────

    function test_spendableNow_takesTheTightestRail() public {
        IAgentMandateVault.MandateTerms memory t = _terms(address(0), 10 ether);
        t.budget = 8 ether;
        t.windowLimit = 3 ether;
        t.windowSeconds = 1 days;
        t.perTxMax = 2 ether;
        uint256 id = _create(t);
        assertEq(vault.spendableNow(id), 2 ether);
        vm.startPrank(agent);
        vault.spend(id, shop, 2 ether, bytes32(0));
        assertEq(vault.spendableNow(id), 1 ether); // window
        vm.warp(block.timestamp + 1 days);
        assertEq(vault.spendableNow(id), 2 ether);
        vm.stopPrank();
        assertEq(vault.spendableNow(77), 0);
    }

    function testFuzz_spendableNowIsExactlySpendable(
        uint96 fundAmt,
        uint96 budget,
        uint96 perTx,
        uint96 window,
        uint96 firstSpend
    ) public {
        IAgentMandateVault.MandateTerms memory t = _terms(address(0), fundAmt);
        t.budget = budget;
        t.perTxMax = perTx;
        t.windowLimit = window;
        t.windowSeconds = 1 days;
        vm.deal(owner, uint256(fundAmt) + 1);
        uint256 id = _create(t);
        uint256 first = bound(firstSpend, 0, vault.spendableNow(id));
        if (first > 0) {
            vm.prank(agent);
            vault.spend(id, shop, first, bytes32(0));
        }
        uint256 cap = vault.spendableNow(id);
        if (cap > 0) {
            vm.prank(agent);
            vault.spend(id, shop, cap, bytes32(0));
        }
        uint256 next = vault.spendableNow(id) + 1;
        vm.prank(agent);
        vm.expectRevert();
        vault.spend(id, shop, next, bytes32(0));
    }

    function test_supportsInterface() public view {
        assertTrue(vault.supportsInterface(0x01ffc9a7));
        assertTrue(vault.supportsInterface(type(IAgentMandateVault).interfaceId));
        assertFalse(vault.supportsInterface(0xffffffff));
    }

    function test_spendDigest_matchesEip712ByHand() public view {
        IAgentMandateVault.SpendAuthorization memory a = _auth(1, 2, 3, 4);
        bytes32 domain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("ERC-AGM AgentMandateVault"),
                keccak256("2"),
                block.chainid,
                address(vault)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "SpendAuthorization(uint256 mandateId,address recipient,uint256 amount,bytes32 receipt,uint256 fee,uint256 nonce,uint256 deadline)"
                ),
                a.mandateId,
                a.recipient,
                a.amount,
                a.receipt,
                a.fee,
                a.nonce,
                a.deadline
            )
        );
        assertEq(vault.spendDigest(a), keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
    }
}
