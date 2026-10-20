// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { PaidReviews } from "../../src/reputation/PaidReviews.sol";
import {
    IERC8004Identity,
    IERC8004Reputation,
    IX402BatchSettlement
} from "../../src/reputation/External.sol";
import { MockIdentity, MockReputation, MockSettlement } from "../mocks/Erc8004AndX402.sol";

contract PaidReviewsTest is Test {
    MockIdentity identity;
    MockReputation reputation;
    MockSettlement settlement;
    PaidReviews reviews;

    address agentOwner = makeAddr("agentOwner");
    address agentWallet = makeAddr("agentWallet");
    address customer = makeAddr("customer");
    address customerKey = makeAddr("customerKey");
    address usdc = makeAddr("usdc");
    uint256 agentId;

    function setUp() public {
        identity = new MockIdentity();
        reputation = new MockReputation(identity);
        settlement = new MockSettlement();
        reviews = new PaidReviews(
            IERC8004Identity(address(identity)),
            IERC8004Reputation(address(reputation)),
            IX402BatchSettlement(address(settlement))
        );
        agentId = identity.register(agentOwner);
        identity.setWallet(agentId, agentWallet);
    }

    function _config(address payer)
        internal
        view
        returns (IX402BatchSettlement.ChannelConfig memory c)
    {
        c = IX402BatchSettlement.ChannelConfig({
            payer: payer,
            payerAuthorizer: customerKey,
            receiver: agentWallet,
            receiverAuthorizer: agentWallet,
            token: usdc,
            withdrawDelay: 15 minutes,
            salt: bytes32(0)
        });
    }

    function _review(int128 v) internal pure returns (PaidReviews.Review memory r) {
        r.value = v;
        r.tag1 = "starred";
        r.feedbackURI = "ipfs://bafy";
    }

    function test_paidCustomerReviews() public {
        IX402BatchSettlement.ChannelConfig memory c = _config(customer);
        settlement.set(c, 10e6, 3e6);
        vm.prank(customer);
        uint64 idx = reviews.reviewX402(agentId, c, _review(90));
        assertEq(idx, 1);
        assertEq(reputation.values(agentId, address(reviews), 1), 90);
        assertEq(reviews.reviewer(agentId, 1), customer);
        assertTrue(reviews.reviewed(settlement.getChannelId(c)));
    }

    function test_payerAuthorizerMayReview() public {
        IX402BatchSettlement.ChannelConfig memory c = _config(customer);
        settlement.set(c, 10e6, 1);
        vm.prank(customerKey);
        reviews.reviewX402(agentId, c, _review(10));
    }

    function test_receiverMayBeTheOwner() public {
        IX402BatchSettlement.ChannelConfig memory c = _config(customer);
        c.receiver = agentOwner;
        settlement.set(c, 10e6, 1);
        vm.prank(customer);
        reviews.reviewX402(agentId, c, _review(10));
    }

    function test_strangerCannotUseSomeoneElsesChannel() public {
        IX402BatchSettlement.ChannelConfig memory c = _config(customer);
        settlement.set(c, 10e6, 1);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(PaidReviews.NotPayer.selector);
        reviews.reviewX402(agentId, c, _review(10));
    }

    function test_zeroAuthorizerIsNotAWildcard() public {
        IX402BatchSettlement.ChannelConfig memory c = _config(customer);
        c.payerAuthorizer = address(0);
        settlement.set(c, 10e6, 1);
        vm.prank(address(0));
        vm.expectRevert(PaidReviews.NotPayer.selector);
        reviews.reviewX402(agentId, c, _review(10));
    }

    function test_nothingClaimedYet() public {
        IX402BatchSettlement.ChannelConfig memory c = _config(customer);
        settlement.set(c, 10e6, 0); // deposited, but the agent has not taken anything
        vm.prank(customer);
        vm.expectRevert(PaidReviews.NothingClaimed.selector);
        reviews.reviewX402(agentId, c, _review(10));
    }

    function test_channelToSomeoneElse() public {
        IX402BatchSettlement.ChannelConfig memory c = _config(customer);
        c.receiver = makeAddr("otherShop");
        settlement.set(c, 10e6, 1);
        vm.prank(customer);
        vm.expectRevert(PaidReviews.NotAgentReceiver.selector);
        reviews.reviewX402(agentId, c, _review(10));
    }

    function test_oneReviewPerChannel() public {
        IX402BatchSettlement.ChannelConfig memory c = _config(customer);
        settlement.set(c, 10e6, 1);
        vm.startPrank(customer);
        reviews.reviewX402(agentId, c, _review(10));
        vm.expectRevert(PaidReviews.AlreadyReviewed.selector);
        reviews.reviewX402(agentId, c, _review(100));
        vm.stopPrank();
    }

    function test_selfReviewsRefused() public {
        // the owner paying its own agent
        IX402BatchSettlement.ChannelConfig memory c = _config(agentOwner);
        c.payerAuthorizer = address(0);
        settlement.set(c, 10e6, 1);
        vm.prank(agentOwner);
        vm.expectRevert(PaidReviews.SelfReview.selector);
        reviews.reviewX402(agentId, c, _review(100));

        // an operator
        address op = makeAddr("operator");
        identity.approve(agentId, op);
        c = _config(op);
        c.payerAuthorizer = address(0);
        settlement.set(c, 10e6, 1);
        vm.prank(op);
        vm.expectRevert(PaidReviews.SelfReview.selector);
        reviews.reviewX402(agentId, c, _review(100));

        // the agent's own wallet
        c = _config(agentWallet);
        c.payerAuthorizer = address(0);
        settlement.set(c, 10e6, 1);
        vm.prank(agentWallet);
        vm.expectRevert(PaidReviews.SelfReview.selector);
        reviews.reviewX402(agentId, c, _review(100));

        // an operator acting as someone else's payer authorizer
        c = _config(customer);
        c.payerAuthorizer = op;
        settlement.set(c, 10e6, 1);
        vm.prank(op);
        vm.expectRevert(PaidReviews.SelfReview.selector);
        reviews.reviewX402(agentId, c, _review(100));
    }

    function test_unknownAgentReverts() public {
        IX402BatchSettlement.ChannelConfig memory c = _config(customer);
        settlement.set(c, 10e6, 1);
        vm.prank(customer);
        vm.expectRevert();
        reviews.reviewX402(999, c, _review(10));
    }

    function test_revokeByReviewerOnly() public {
        IX402BatchSettlement.ChannelConfig memory c = _config(customer);
        settlement.set(c, 10e6, 1);
        vm.prank(customer);
        uint64 idx = reviews.reviewX402(agentId, c, _review(10));
        vm.prank(makeAddr("someoneElse"));
        vm.expectRevert(PaidReviews.NotReviewer.selector);
        reviews.revoke(agentId, idx);
        vm.prank(customer);
        reviews.revoke(agentId, idx);
        assertTrue(reputation.revoked(agentId, address(reviews), idx));
    }

    function test_channelIdIsChainBound() public {
        IX402BatchSettlement.ChannelConfig memory c = _config(customer);
        settlement.set(c, 10e6, 1);
        bytes32 here = settlement.getChannelId(c);
        vm.chainId(block.chainid + 1);
        assertTrue(settlement.getChannelId(c) != here);
    }
}
