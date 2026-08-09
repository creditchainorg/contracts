// Copyright (c) CreditChain Research Team. All rights reserved.
// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { CreditNFTCollection } from "../src/CreditNFTCollection.sol";
import { CreditNFTFactory } from "../src/CreditNFTFactory.sol";
import { CreditNFTMarket } from "../src/CreditNFTMarket.sol";

contract RejectingNFTReceiver {
    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert("reject NFT");
    }
}

contract ExcessiveRoyaltyNFT {
    address public tokenOwner;
    address public approvedMarket;

    constructor(address tokenOwner_) {
        tokenOwner = tokenOwner_;
    }

    function setApprovedMarket(address market) external {
        require(msg.sender == tokenOwner, "not owner");
        approvedMarket = market;
    }

    function ownerOf(uint256) external view returns (address) {
        return tokenOwner;
    }

    function getApproved(uint256) external view returns (address) {
        return approvedMarket;
    }

    function isApprovedForAll(address, address) external pure returns (bool) {
        return false;
    }

    function safeTransferFrom(address from, address to, uint256) external {
        require(msg.sender == approvedMarket && from == tokenOwner, "not approved");
        tokenOwner = to;
    }

    function royaltyInfo(uint256, uint256 salePrice) external view returns (address, uint256) {
        return (address(this), salePrice);
    }
}

contract CreditNFTMarketTest is Test {
    CreditNFTCollection collection;
    CreditNFTMarket market;

    address admin = address(0xAD11);
    address creator = address(0xC0FFEE);
    address collector = address(0xB0B);
    address principal = address(0xA11CE);
    address feeRecipient = address(0xFEE);
    address royaltyTreasury = address(0xBEEF);
    uint256 tokenId;

    function setUp() public {
        vm.prank(creator);
        collection = new CreditNFTCollection(
            "CreditChain Origins",
            "ORIGIN",
            creator,
            100,
            "ipfs://collection",
            keccak256("signed-origin-manifest"),
            royaltyTreasury,
            500
        );
        vm.prank(admin);
        market = new CreditNFTMarket(feeRecipient, 250);

        vm.prank(creator);
        tokenId = collection.safeMint(creator, "ipfs://token-1");
        vm.deal(collector, 100 ether);
    }

    function _list(uint256 price, uint64 expiry) internal returns (uint256 listingId) {
        vm.startPrank(creator);
        collection.approve(address(market), tokenId);
        listingId = market.list(address(collection), tokenId, price, expiry);
        vm.stopPrank();
    }

    function test_collectionImplementsOwnershipMetadataAndRoyalty() public view {
        assertEq(collection.ownerOf(tokenId), creator);
        assertEq(collection.tokenURI(tokenId), "ipfs://token-1");
        assertEq(collection.totalSupply(), 1);
        assertEq(collection.maxSupply(), 100);

        (address receiver, uint256 amount) = collection.royaltyInfo(tokenId, 10 ether);
        assertEq(receiver, royaltyTreasury);
        assertEq(amount, 0.5 ether);
    }

    function test_buySplitsPullPaymentsAndTransfersNFT() public {
        uint256 listingId = _list(10 ether, uint64(block.timestamp + 1 days));

        vm.prank(collector);
        market.buy{ value: 10 ether }(listingId);

        assertEq(collection.ownerOf(tokenId), collector);
        assertEq(market.proceeds(creator), 9.25 ether);
        assertEq(market.proceeds(feeRecipient), 0.25 ether);
        assertEq(market.proceeds(royaltyTreasury), 0.5 ether);
        assertEq(address(market).balance, 10 ether);
        assertEq(market.activeListing(keccak256(abi.encode(address(collection), tokenId))), 0);
    }

    function test_agentCanBuyDirectlyForPrincipal() public {
        uint256 listingId = _list(2 ether, uint64(block.timestamp + 1 days));

        vm.prank(collector);
        market.buyFor{ value: 2 ether }(listingId, principal);

        assertEq(collection.ownerOf(tokenId), principal);
        assertEq(market.proceeds(creator), 1.85 ether);
    }

    function test_withdrawProceedsUsesChosenRecipient() public {
        uint256 listingId = _list(10 ether, uint64(block.timestamp + 1 days));
        vm.prank(collector);
        market.buy{ value: 10 ether }(listingId);

        address payable payout = payable(address(0xCAFE));
        vm.prank(creator);
        market.withdrawProceeds(payout);

        assertEq(payout.balance, 9.25 ether);
        assertEq(market.proceeds(creator), 0);
    }

    function test_rejectsWrongPayment() public {
        uint256 listingId = _list(10 ether, uint64(block.timestamp + 1 days));
        vm.prank(collector);
        vm.expectRevert(CreditNFTMarket.WrongPayment.selector);
        market.buy{ value: 9 ether }(listingId);
    }

    function test_expiredListingCannotBeBoughtAndCanBeInvalidated() public {
        uint256 listingId = _list(10 ether, uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 1 days);

        vm.prank(collector);
        vm.expectRevert(CreditNFTMarket.ListingExpired.selector);
        market.buy{ value: 10 ether }(listingId);

        vm.prank(collector);
        market.invalidate(listingId);
        assertEq(market.listingIsValid(listingId), false);
    }

    function test_transferredListingIsStale() public {
        uint256 listingId = _list(10 ether, uint64(block.timestamp + 1 days));
        vm.prank(creator);
        collection.transferFrom(creator, principal, tokenId);

        vm.prank(collector);
        vm.expectRevert(CreditNFTMarket.ListingStale.selector);
        market.buy{ value: 10 ether }(listingId);

        vm.prank(principal);
        market.invalidate(listingId);
        assertEq(market.listingIsValid(listingId), false);
    }

    function test_onlySellerCanCancel() public {
        uint256 listingId = _list(10 ether, uint64(block.timestamp + 1 days));
        vm.prank(collector);
        vm.expectRevert(CreditNFTMarket.NotSeller.selector);
        market.cancel(listingId);

        vm.prank(creator);
        market.cancel(listingId);
        assertEq(market.listingIsValid(listingId), false);
    }

    function test_purchasePauseLeavesCancellationAndWithdrawalAvailable() public {
        uint256 listingId = _list(10 ether, uint64(block.timestamp + 1 days));
        vm.prank(admin);
        market.setPurchasesPaused(true);

        vm.prank(collector);
        vm.expectRevert(CreditNFTMarket.PurchasesArePaused.selector);
        market.buy{ value: 10 ether }(listingId);

        vm.prank(creator);
        market.cancel(listingId);
    }

    function test_collectionFreezeIsPermanent() public {
        vm.prank(creator);
        collection.freezeCollection();

        vm.prank(creator);
        vm.expectRevert(CreditNFTCollection.CollectionIsFrozen.selector);
        collection.safeMint(creator, "ipfs://token-2");

        vm.prank(creator);
        vm.expectRevert(CreditNFTCollection.CollectionIsFrozen.selector);
        collection.setTokenURI(tokenId, "ipfs://mutated");
    }

    function test_marketFeeHasHardCap() public {
        vm.prank(admin);
        vm.expectRevert(CreditNFTMarket.FeeTooHigh.selector);
        market.setMarketFee(feeRecipient, 251);
    }

    function test_rejectingReceiverRollsBackSaleAndAccounting() public {
        uint256 listingId = _list(10 ether, uint64(block.timestamp + 1 days));
        RejectingNFTReceiver receiver = new RejectingNFTReceiver();

        vm.prank(collector);
        vm.expectRevert(CreditNFTCollection.UnsafeRecipient.selector);
        market.buyFor{ value: 10 ether }(listingId, address(receiver));

        assertEq(collection.ownerOf(tokenId), creator);
        assertTrue(market.listingIsValid(listingId));
        assertEq(market.proceeds(creator), 0);
        assertEq(address(market).balance, 0);
    }

    function test_excessiveRoyaltyCannotConsumeSellerProceeds() public {
        ExcessiveRoyaltyNFT hostile = new ExcessiveRoyaltyNFT(creator);
        vm.prank(creator);
        hostile.setApprovedMarket(address(market));
        vm.prank(creator);
        uint256 listingId =
            market.list(address(hostile), 1, 10 ether, uint64(block.timestamp + 1 days));

        vm.prank(collector);
        vm.expectRevert(CreditNFTMarket.ExcessiveRoyalty.selector);
        market.buy{ value: 10 ether }(listingId);

        assertEq(hostile.tokenOwner(), creator);
        assertTrue(market.listingIsValid(listingId));
        assertEq(address(market).balance, 0);
    }

    function test_factoryCreatesCreatorOwnedCollectionWithoutAdminAuthority() public {
        CreditNFTFactory factory = new CreditNFTFactory();
        bytes32 provenance = keccak256("factory-origin-manifest");

        vm.prank(creator);
        address created = factory.createCollection(
            "Factory Origins",
            "FORIGIN",
            50,
            "ipfs://factory-collection",
            provenance,
            royaltyTreasury,
            500
        );

        CreditNFTCollection factoryCollection = CreditNFTCollection(created);
        assertEq(factoryCollection.owner(), creator);
        assertTrue(factoryCollection.minters(creator));
        assertEq(factory.collectionCount(), 1);
        assertEq(factory.collectionAt(1), created);
        assertTrue(factory.createdHere(created));
    }

    function test_collectionRejectsMissingProvenanceCommitment() public {
        vm.expectRevert(CreditNFTCollection.InvalidProvenance.selector);
        new CreditNFTCollection(
            "No Provenance",
            "NONE",
            creator,
            1,
            "ipfs://collection",
            bytes32(0),
            royaltyTreasury,
            500
        );
    }

    function test_collectionRejectsEmptyDocumentProvenanceCommitment() public {
        vm.expectRevert(CreditNFTCollection.InvalidProvenance.selector);
        new CreditNFTCollection(
            "Empty Provenance",
            "EMPTY",
            creator,
            1,
            "ipfs://collection",
            keccak256(""),
            royaltyTreasury,
            500
        );
    }

    function test_collectionAdvertisesOwnershipRoyaltyAndMetadataUpdateInterfaces() public view {
        assertTrue(collection.supportsInterface(0x80ac58cd)); // ERC-721
        assertTrue(collection.supportsInterface(0x5b5e139f)); // ERC-721 metadata
        assertTrue(collection.supportsInterface(0x2a55205a)); // ERC-2981
        assertTrue(collection.supportsInterface(0x49064906)); // ERC-4906
    }

    function testFuzz_saleConservesExactPrice(
        uint96 rawPrice,
        uint16 rawRoyaltyBps,
        uint16 rawMarketFeeBps
    ) public {
        uint256 price = bound(uint256(rawPrice), 1, 100 ether);
        uint96 royaltyBps = uint96(bound(uint256(rawRoyaltyBps), 0, 1_000));
        uint96 marketFeeBps = uint96(bound(uint256(rawMarketFeeBps), 0, 250));

        vm.prank(creator);
        CreditNFTCollection fuzzCollection = new CreditNFTCollection(
            "Fuzz Origins",
            "FUZZ",
            creator,
            1,
            "ipfs://fuzz-collection",
            keccak256("fuzz-origin-manifest"),
            royaltyTreasury,
            royaltyBps
        );
        vm.prank(admin);
        CreditNFTMarket fuzzMarket = new CreditNFTMarket(feeRecipient, marketFeeBps);

        vm.startPrank(creator);
        uint256 fuzzTokenId = fuzzCollection.safeMint(creator, "ipfs://fuzz-token");
        fuzzCollection.approve(address(fuzzMarket), fuzzTokenId);
        uint256 listingId = fuzzMarket.list(
            address(fuzzCollection), fuzzTokenId, price, uint64(block.timestamp + 1 days)
        );
        vm.stopPrank();

        vm.deal(collector, price);
        vm.prank(collector);
        fuzzMarket.buyFor{ value: price }(listingId, principal);

        uint256 accounted = fuzzMarket.proceeds(creator) + fuzzMarket.proceeds(feeRecipient)
            + fuzzMarket.proceeds(royaltyTreasury);
        assertEq(accounted, price);
        assertEq(address(fuzzMarket).balance, price);
        assertEq(fuzzCollection.ownerOf(fuzzTokenId), principal);
        assertEq(
            fuzzMarket.activeListing(keccak256(abi.encode(address(fuzzCollection), fuzzTokenId))), 0
        );
    }
}
