// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CreditAgentFinance} from "../src/CreditAgentFinance.sol";

/// Regression tests for a NON-CUSTODIAL preview registry, not a spending vault.
contract CreditAgentFinanceTest is Test {
    CreditAgentFinance internal registry;
    address internal controller = address(0xA11CE);
    address internal merchant = address(0xB0B);
    bytes32 internal constant AGENT = keccak256("agent");
    bytes32 internal constant PERMIT = keccak256("permit");
    bytes32 internal constant INTENT = keccak256("intent");

    function setUp() public {
        registry = new CreditAgentFinance();
        vm.warp(100);
        registry.registerAgent(AGENT, controller, "ipfs://agent");
        _permit(PERMIT, 1 ether, 10 ether, 100, 200);
    }

    function _permit(bytes32 id, uint256 daily, uint256 total, uint64 start, uint64 end) internal {
        registry.createSpendPermit(id, AGENT, address(0), daily, total, start, end, bytes32(0), "");
    }

    function _intent(bytes32 id, bytes32 permit, uint256 amount) internal {
        registry.createPaymentIntent(id, permit, merchant, amount, bytes32(0), "");
    }

    function testRegistrationStoresOwnerAndController() public view {
        (address owner, address actual, string memory uri, bool active) = registry.agents(AGENT);
        assertEq(owner, address(this));
        assertEq(actual, controller);
        assertEq(uri, "ipfs://agent");
        assertTrue(active);
    }

    function testRegistrationRejectsZeroAndDuplicate() public {
        vm.expectRevert("agent id required");
        registry.registerAgent(bytes32(0), controller, "");
        vm.expectRevert("controller required");
        registry.registerAgent(keccak256("new"), address(0), "");
        vm.expectRevert("agent exists");
        registry.registerAgent(AGENT, merchant, "");
    }

    function testFuzzOnlyOwnerCanRotate(address outsider) public {
        vm.assume(outsider != address(this));
        vm.prank(outsider);
        vm.expectRevert("not agent owner");
        registry.updateAgentController(AGENT, merchant);
    }

    function testRotationRemovesOldControllerAuthority() public {
        registry.updateAgentController(AGENT, merchant);
        vm.prank(controller);
        vm.expectRevert("not authorized");
        _intent(INTENT, PERMIT, 1);
        vm.prank(merchant);
        _intent(INTENT, PERMIT, 1);
    }

    function testControllerCannotIssueOrRevokePermit() public {
        vm.startPrank(controller);
        vm.expectRevert("not agent owner");
        _permit(keccak256("other"), 1, 2, 100, 200);
        vm.expectRevert("not permit issuer");
        registry.revokeSpendPermit(PERMIT, "");
        vm.stopPrank();
    }

    function testPermitValidation() public {
        bytes32 id = keccak256("other");
        vm.expectRevert("permit id required");
        _permit(bytes32(0), 1, 2, 100, 200);
        vm.expectRevert("permit exists");
        _permit(PERMIT, 1, 2, 100, 200);
        vm.expectRevert("invalid validity");
        _permit(id, 1, 2, 200, 200);
        vm.expectRevert("daily exceeds total");
        _permit(id, 3, 2, 100, 200);
    }

    function testValidityBoundaries() public {
        vm.warp(99);
        vm.expectRevert("permit not active");
        _intent(INTENT, PERMIT, 1);
        vm.warp(100);
        _intent(INTENT, PERMIT, 1);
        vm.warp(200);
        _intent(keccak256("end-inclusive"), PERMIT, 1);
        vm.warp(201);
        vm.expectRevert("permit expired");
        _intent(keccak256("late"), PERMIT, 1);
    }

    function testRevocationIsPermanentForNewIntents() public {
        registry.revokeSpendPermit(PERMIT, "stop");
        vm.expectRevert("permit revoked");
        _intent(INTENT, PERMIT, 1);
        vm.expectRevert("permit revoked");
        registry.revokeSpendPermit(PERMIT, "again");
    }

    function testIntentIdsAndAmountBound() public {
        vm.expectRevert("intent id required");
        _intent(bytes32(0), PERMIT, 1);
        vm.expectRevert("amount exceeds permit");
        _intent(INTENT, PERMIT, 10 ether + 1);
        _intent(INTENT, PERMIT, 10 ether);
        vm.expectRevert("intent exists");
        _intent(INTENT, PERMIT, 1);
    }

    function testFuzzOutsiderCannotCreateIntent(address outsider) public {
        vm.assume(outsider != address(this) && outsider != controller);
        vm.prank(outsider);
        vm.expectRevert("not authorized");
        _intent(INTENT, PERMIT, 1);
    }

    function testMissingIntentAndUnauthorizedReceiptRejected() public {
        vm.expectRevert("intent missing");
        registry.recordTaskReceipt(bytes32(0), INTENT, bytes32(0), "");
        _intent(INTENT, PERMIT, 1);
        vm.prank(address(0xBAD));
        vm.expectRevert("not authorized");
        registry.recordTaskReceipt(bytes32(0), INTENT, bytes32(0), "");
    }

    function testSettlementAuthorizationAndDuplicateProtection() public {
        vm.expectRevert("intent missing");
        registry.settlePaymentIntent(INTENT, bytes32(0), bytes32(0), "");
        _intent(INTENT, PERMIT, 1);
        vm.prank(address(0xBAD));
        vm.expectRevert("not authorized");
        registry.settlePaymentIntent(INTENT, bytes32(0), bytes32(0), "");
        vm.prank(merchant);
        registry.settlePaymentIntent(INTENT, bytes32(0), bytes32(0), "");
        vm.expectRevert("already settled");
        registry.settlePaymentIntent(INTENT, bytes32(0), bytes32(0), "");
    }

    function testPreviewDoesNotEnforceCumulativeOrDailySpending() public {
        // Explicit semantic boundary: both intents exceed dailyLimit and sum exceeds totalLimit.
        // Never advertise this preview as the custody-enforcing AgentSpendVault.
        _intent(INTENT, PERMIT, 10 ether);
        _intent(keccak256("second"), PERMIT, 10 ether);
        assertEq(address(registry).balance, 0);
    }

    function testSettlementIsAClaimNotAFundsTransfer() public {
        _intent(INTENT, PERMIT, 10 ether);
        uint256 beforeBalance = merchant.balance;
        registry.settlePaymentIntent(INTENT, bytes32(0), bytes32(0), "unverified assertion");
        assertEq(merchant.balance, beforeBalance);
        assertEq(address(registry).balance, 0);
    }

    function testCreditObjectIssuerControlsClaims() public {
        bytes32 id = keccak256("object");
        registry.createCreditObject(
            id, CreditAgentFinance.CreditObjectType.Invoice, merchant, address(0), 10, bytes32(0), ""
        );
        vm.prank(merchant);
        vm.expectRevert("not issuer");
        registry.updateCreditObjectStatus(id, CreditAgentFinance.CreditObjectStatus.Settled, "");
        // A status is an issuer's claim, not a verified settlement state machine.
        registry.updateCreditObjectStatus(id, CreditAgentFinance.CreditObjectStatus.Settled, "");
        vm.expectRevert("object exists");
        registry.createCreditObject(
            id, CreditAgentFinance.CreditObjectType.Invoice, merchant, address(0), 10, bytes32(0), ""
        );
    }
}
