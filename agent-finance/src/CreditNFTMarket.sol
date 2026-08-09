// Copyright (c) CreditChain Research Team. All rights reserved.
// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.24;

interface IERC721MarketAsset {
    function ownerOf(uint256 tokenId) external view returns (address);
    function getApproved(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

interface IERC2981MarketRoyalty {
    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        external
        view
        returns (address receiver, uint256 royaltyAmount);
}

/// @title CreditNFTMarket
/// @notice Non-custodial fixed-price ERC-721 market settled in native CCC.
/// Listings never escrow NFTs. Sales use pull-based proceeds, recognize ERC-2981
/// royalties, and support buying directly for a separate recipient (including an
/// agent's principal). Cancellation and withdrawals remain available while paused.
///
/// @dev Public-testnet v1. Offers, auctions, ERC-1155 and signed off-chain orders
/// belong in separately audited protocol modules rather than being hidden here.
contract CreditNFTMarket {
    uint96 public constant MAX_MARKET_FEE_BPS = 250;
    uint96 private constant BPS_DENOMINATOR = 10_000;
    bytes4 private constant ROYALTY_INFO_SELECTOR = 0x2a55205a;

    struct Listing {
        address seller;
        address nft;
        uint256 tokenId;
        uint256 price;
        uint64 expiresAt;
    }

    address public owner;
    address public pendingOwner;
    address public feeRecipient;
    uint96 public marketFeeBps;
    uint256 public nextListingId = 1;
    bool public purchasesPaused;

    mapping(uint256 => Listing) public listings;
    mapping(bytes32 => uint256) public activeListing;
    mapping(address => uint256) public proceeds;

    uint256 private _locked = 1;

    event Listed(
        uint256 indexed listingId,
        address indexed seller,
        address indexed nft,
        uint256 tokenId,
        uint256 price,
        uint64 expiresAt
    );
    event ListingCancelled(uint256 indexed listingId, address indexed seller);
    event ListingInvalidated(uint256 indexed listingId, address indexed caller);
    event Sale(
        uint256 indexed listingId,
        address indexed buyer,
        address indexed recipient,
        address seller,
        address nft,
        uint256 tokenId,
        uint256 price,
        address royaltyReceiver,
        uint256 royaltyAmount,
        uint256 marketFee
    );
    event ProceedsWithdrawn(address indexed account, address indexed recipient, uint256 amount);
    event MarketFeeUpdated(address indexed recipient, uint96 bps);
    event PurchasesPaused(bool paused);
    event OwnershipTransferStarted(address indexed currentOwner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error InvalidPrice();
    error InvalidExpiry();
    error FeeTooHigh();
    error AlreadyListed();
    error NotTokenOwner();
    error MarketNotApproved();
    error ListingNotFound();
    error NotSeller();
    error ListingExpired();
    error ListingStillValid();
    error ListingStale();
    error WrongPayment();
    error PurchasesArePaused();
    error ExcessiveRoyalty();
    error NoProceeds();
    error TransferFailed();
    error ReentrantCall();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_locked != 1) revert ReentrantCall();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(address feeRecipient_, uint96 marketFeeBps_) {
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        if (marketFeeBps_ > MAX_MARKET_FEE_BPS) revert FeeTooHigh();
        owner = msg.sender;
        feeRecipient = feeRecipient_;
        marketFeeBps = marketFeeBps_;
        emit OwnershipTransferred(address(0), msg.sender);
        emit MarketFeeUpdated(feeRecipient_, marketFeeBps_);
    }

    // ─────────────────────────── market actions ───────────────────────────

    function list(address nft, uint256 tokenId, uint256 price, uint64 expiresAt)
        external
        returns (uint256 listingId)
    {
        if (nft == address(0)) revert ZeroAddress();
        if (price == 0) revert InvalidPrice();
        if (expiresAt <= block.timestamp) revert InvalidExpiry();

        bytes32 assetKey = _assetKey(nft, tokenId);
        if (activeListing[assetKey] != 0) revert AlreadyListed();

        IERC721MarketAsset asset = IERC721MarketAsset(nft);
        if (asset.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (!_isApproved(asset, msg.sender, tokenId)) revert MarketNotApproved();

        listingId = nextListingId++;
        listings[listingId] = Listing(msg.sender, nft, tokenId, price, expiresAt);
        activeListing[assetKey] = listingId;
        emit Listed(listingId, msg.sender, nft, tokenId, price, expiresAt);
    }

    function cancel(uint256 listingId) external {
        Listing memory listing = listings[listingId];
        if (listing.seller == address(0)) revert ListingNotFound();
        if (msg.sender != listing.seller) revert NotSeller();
        _deleteListing(listingId, listing);
        emit ListingCancelled(listingId, listing.seller);
    }

    /// @notice Clears an expired, transferred or unapproved listing. Anyone may
    /// prune stale state, but a valid listing can only be cancelled by its seller.
    function invalidate(uint256 listingId) external {
        Listing memory listing = listings[listingId];
        if (listing.seller == address(0)) revert ListingNotFound();
        if (_listingIsValid(listing)) revert ListingStillValid();
        _deleteListing(listingId, listing);
        emit ListingInvalidated(listingId, msg.sender);
    }

    function buy(uint256 listingId) external payable {
        buyFor(listingId, msg.sender);
    }

    /// @notice Pays for a listing and transfers the NFT directly to `recipient`.
    /// This is the agent-commerce primitive: the payer and final owner may differ.
    function buyFor(uint256 listingId, address recipient) public payable nonReentrant {
        if (purchasesPaused) revert PurchasesArePaused();
        if (recipient == address(0)) revert ZeroAddress();

        Listing memory listing = listings[listingId];
        if (listing.seller == address(0)) revert ListingNotFound();
        if (block.timestamp >= listing.expiresAt) revert ListingExpired();
        if (msg.value != listing.price) revert WrongPayment();

        IERC721MarketAsset asset = IERC721MarketAsset(listing.nft);
        if (asset.ownerOf(listing.tokenId) != listing.seller) revert ListingStale();
        if (!_isApproved(asset, listing.seller, listing.tokenId)) revert ListingStale();

        uint256 marketFee = (listing.price * marketFeeBps) / BPS_DENOMINATOR;
        (address royaltyReceiver, uint256 royaltyAmount) =
            _royalty(listing.nft, listing.tokenId, listing.price);
        if (royaltyAmount > listing.price - marketFee) revert ExcessiveRoyalty();

        _deleteListing(listingId, listing);
        proceeds[listing.seller] += listing.price - marketFee - royaltyAmount;
        if (marketFee != 0) proceeds[feeRecipient] += marketFee;
        if (royaltyAmount != 0) proceeds[royaltyReceiver] += royaltyAmount;
        asset.safeTransferFrom(listing.seller, recipient, listing.tokenId);

        emit Sale(
            listingId,
            msg.sender,
            recipient,
            listing.seller,
            listing.nft,
            listing.tokenId,
            listing.price,
            royaltyReceiver,
            royaltyAmount,
            marketFee
        );
    }

    function withdrawProceeds(address payable recipient) external nonReentrant {
        if (recipient == address(0)) revert ZeroAddress();
        uint256 amount = proceeds[msg.sender];
        if (amount == 0) revert NoProceeds();
        proceeds[msg.sender] = 0;
        (bool ok,) = recipient.call{ value: amount }("");
        if (!ok) revert TransferFailed();
        emit ProceedsWithdrawn(msg.sender, recipient, amount);
    }

    // ─────────────────────────── administration ───────────────────────────

    function setMarketFee(address recipient, uint96 bps) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        if (bps > MAX_MARKET_FEE_BPS) revert FeeTooHigh();
        feeRecipient = recipient;
        marketFeeBps = bps;
        emit MarketFeeUpdated(recipient, bps);
    }

    /// @notice Pauses purchases only. Sellers can cancel and everyone can withdraw.
    function setPurchasesPaused(bool paused) external onlyOwner {
        purchasesPaused = paused;
        emit PurchasesPaused(paused);
    }

    function transferOwnership(address nextOwner) external onlyOwner {
        if (nextOwner == address(0)) revert ZeroAddress();
        pendingOwner = nextOwner;
        emit OwnershipTransferStarted(owner, nextOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address previous = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, msg.sender);
    }

    // ─────────────────────────── views ───────────────────────────

    function listingIsValid(uint256 listingId) external view returns (bool) {
        Listing memory listing = listings[listingId];
        return listing.seller != address(0) && _listingIsValid(listing);
    }

    function _listingIsValid(Listing memory listing) private view returns (bool) {
        if (block.timestamp >= listing.expiresAt) return false;
        IERC721MarketAsset asset = IERC721MarketAsset(listing.nft);
        try asset.ownerOf(listing.tokenId) returns (address tokenOwner) {
            if (tokenOwner != listing.seller) return false;
        } catch {
            return false;
        }
        return _isApproved(asset, listing.seller, listing.tokenId);
    }

    function _isApproved(IERC721MarketAsset asset, address tokenOwner, uint256 tokenId)
        private
        view
        returns (bool)
    {
        try asset.getApproved(tokenId) returns (address approved) {
            if (approved == address(this)) return true;
        } catch { }
        try asset.isApprovedForAll(tokenOwner, address(this)) returns (bool approvedForAll) {
            return approvedForAll;
        } catch {
            return false;
        }
    }

    function _royalty(address nft, uint256 tokenId, uint256 salePrice)
        private
        view
        returns (address receiver, uint256 amount)
    {
        (bool ok, bytes memory data) =
            nft.staticcall(abi.encodeWithSelector(ROYALTY_INFO_SELECTOR, tokenId, salePrice));
        if (!ok || data.length < 64) return (address(0), 0);
        (receiver, amount) = abi.decode(data, (address, uint256));
        if (receiver == address(0)) amount = 0;
    }

    function _deleteListing(uint256 listingId, Listing memory listing) private {
        delete activeListing[_assetKey(listing.nft, listing.tokenId)];
        delete listings[listingId];
    }

    function _assetKey(address nft, uint256 tokenId) private pure returns (bytes32) {
        return keccak256(abi.encode(nft, tokenId));
    }
}
