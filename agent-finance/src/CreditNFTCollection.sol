// Copyright (c) CreditChain Research Team. All rights reserved.
// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.24;

interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

interface IERC721 is IERC165 {
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    function balanceOf(address owner) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data)
        external;
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
    function approve(address to, uint256 tokenId) external;
    function setApprovalForAll(address operator, bool approved) external;
    function getApproved(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
}

interface IERC721Metadata is IERC721 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function tokenURI(uint256 tokenId) external view returns (string memory);
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

interface IERC2981 is IERC165 {
    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        external
        view
        returns (address receiver, uint256 royaltyAmount);
}

/// @title CreditNFTCollection
/// @notice A compact ERC-721 + ERC-2981 reference collection for CreditChain.
/// Creators retain minting control, publish a collection-level provenance hash,
/// and can permanently freeze supply, metadata, minters and royalties.
///
/// @dev This is a transparent reference implementation for the public testnet.
/// It intentionally avoids upgradeability. Production collections should use a
/// separately audited release and independently review their metadata storage.
contract CreditNFTCollection is IERC721Metadata, IERC2981 {
    uint96 public constant MAX_ROYALTY_BPS = 1_000;
    bytes32 public constant EMPTY_PROVENANCE_HASH =
        0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
    uint96 private constant BPS_DENOMINATOR = 10_000;

    string public override name;
    string public override symbol;
    string public contractURI;
    bytes32 public immutable provenanceHash;
    uint256 public immutable maxSupply;

    address public owner;
    address public pendingOwner;
    address public royaltyReceiver;
    uint96 public royaltyBps;
    uint256 public totalMinted;
    uint256 public totalSupply;
    bool public collectionFrozen;

    mapping(address => bool) public minters;
    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;
    mapping(uint256 => string) private _tokenURIs;

    event OwnershipTransferStarted(address indexed currentOwner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event MinterUpdated(address indexed minter, bool allowed);
    event TokenURIUpdated(uint256 indexed tokenId, string uri);
    event MetadataUpdate(uint256 indexed tokenId);
    event BatchMetadataUpdate(uint256 indexed fromTokenId, uint256 indexed toTokenId);
    event ContractURIUpdated();
    event RoyaltyUpdated(address indexed receiver, uint96 bps);
    event CollectionFrozen(uint256 finalSupply, bytes32 indexed provenanceHash);

    error NotOwner();
    error NotPendingOwner();
    error NotMinter();
    error ZeroAddress();
    error InvalidSupply();
    error InvalidProvenance();
    error SupplyExhausted();
    error CollectionIsFrozen();
    error RoyaltyTooHigh();
    error TokenDoesNotExist();
    error NotAuthorized();
    error WrongOwner();
    error UnsafeRecipient();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyMinter() {
        if (!minters[msg.sender]) revert NotMinter();
        _;
    }

    modifier mutableCollection() {
        if (collectionFrozen) revert CollectionIsFrozen();
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        address initialOwner_,
        uint256 maxSupply_,
        string memory contractURI_,
        bytes32 provenanceHash_,
        address royaltyReceiver_,
        uint96 royaltyBps_
    ) {
        if (initialOwner_ == address(0) || royaltyReceiver_ == address(0)) revert ZeroAddress();
        if (maxSupply_ == 0) revert InvalidSupply();
        if (provenanceHash_ == bytes32(0) || provenanceHash_ == EMPTY_PROVENANCE_HASH) {
            revert InvalidProvenance();
        }
        if (royaltyBps_ > MAX_ROYALTY_BPS) revert RoyaltyTooHigh();

        name = name_;
        symbol = symbol_;
        maxSupply = maxSupply_;
        contractURI = contractURI_;
        provenanceHash = provenanceHash_;
        owner = initialOwner_;
        royaltyReceiver = royaltyReceiver_;
        royaltyBps = royaltyBps_;
        minters[initialOwner_] = true;

        emit OwnershipTransferred(address(0), initialOwner_);
        emit MinterUpdated(initialOwner_, true);
        emit RoyaltyUpdated(royaltyReceiver_, royaltyBps_);
    }

    // ─────────────────────────── creator controls ───────────────────────────

    function setMinter(address minter, bool allowed) external onlyOwner mutableCollection {
        if (minter == address(0)) revert ZeroAddress();
        minters[minter] = allowed;
        emit MinterUpdated(minter, allowed);
    }

    function setTokenURI(uint256 tokenId, string calldata uri)
        external
        onlyOwner
        mutableCollection
    {
        if (_owners[tokenId] == address(0)) revert TokenDoesNotExist();
        _tokenURIs[tokenId] = uri;
        emit TokenURIUpdated(tokenId, uri);
        emit MetadataUpdate(tokenId);
    }

    function setContractURI(string calldata uri) external onlyOwner mutableCollection {
        contractURI = uri;
        emit ContractURIUpdated();
    }

    function setRoyalty(address receiver, uint96 bps) external onlyOwner mutableCollection {
        if (receiver == address(0)) revert ZeroAddress();
        if (bps > MAX_ROYALTY_BPS) revert RoyaltyTooHigh();
        royaltyReceiver = receiver;
        royaltyBps = bps;
        emit RoyaltyUpdated(receiver, bps);
    }

    /// @notice Permanently closes minting and every mutable collection setting.
    function freezeCollection() external onlyOwner mutableCollection {
        collectionFrozen = true;
        emit CollectionFrozen(totalSupply, provenanceHash);
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

    // ─────────────────────────── mint / burn ───────────────────────────

    function safeMint(address to, string calldata uri)
        external
        onlyMinter
        mutableCollection
        returns (uint256 tokenId)
    {
        if (to == address(0)) revert ZeroAddress();
        if (totalMinted >= maxSupply) revert SupplyExhausted();

        tokenId = ++totalMinted;
        totalSupply += 1;
        _owners[tokenId] = to;
        _balances[to] += 1;
        _tokenURIs[tokenId] = uri;

        emit Transfer(address(0), to, tokenId);
        emit TokenURIUpdated(tokenId, uri);
        _checkOnERC721Received(address(0), to, tokenId, "");
    }

    function burn(uint256 tokenId) external {
        address tokenOwner = ownerOf(tokenId);
        if (!_isAuthorized(msg.sender, tokenOwner, tokenId)) revert NotAuthorized();

        delete _tokenApprovals[tokenId];
        delete _owners[tokenId];
        delete _tokenURIs[tokenId];
        _balances[tokenOwner] -= 1;
        totalSupply -= 1;
        emit Transfer(tokenOwner, address(0), tokenId);
    }

    // ─────────────────────────── ERC-721 ───────────────────────────

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC721).interfaceId
            || interfaceId == type(IERC721Metadata).interfaceId
            || interfaceId == type(IERC2981).interfaceId || interfaceId == bytes4(0x49064906);
    }

    function balanceOf(address account) external view override returns (uint256) {
        if (account == address(0)) revert ZeroAddress();
        return _balances[account];
    }

    function ownerOf(uint256 tokenId) public view override returns (address tokenOwner) {
        tokenOwner = _owners[tokenId];
        if (tokenOwner == address(0)) revert TokenDoesNotExist();
    }

    function tokenURI(uint256 tokenId) external view override returns (string memory) {
        if (_owners[tokenId] == address(0)) revert TokenDoesNotExist();
        return _tokenURIs[tokenId];
    }

    function approve(address approved, uint256 tokenId) external override {
        address tokenOwner = ownerOf(tokenId);
        if (msg.sender != tokenOwner && !_operatorApprovals[tokenOwner][msg.sender]) {
            revert NotAuthorized();
        }
        _tokenApprovals[tokenId] = approved;
        emit Approval(tokenOwner, approved, tokenId);
    }

    function getApproved(uint256 tokenId) external view override returns (address) {
        if (_owners[tokenId] == address(0)) revert TokenDoesNotExist();
        return _tokenApprovals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) external override {
        if (operator == msg.sender) revert NotAuthorized();
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address tokenOwner, address operator)
        external
        view
        override
        returns (bool)
    {
        return _operatorApprovals[tokenOwner][operator];
    }

    function transferFrom(address from, address to, uint256 tokenId) public override {
        address tokenOwner = ownerOf(tokenId);
        if (tokenOwner != from) revert WrongOwner();
        if (to == address(0)) revert ZeroAddress();
        if (!_isAuthorized(msg.sender, tokenOwner, tokenId)) revert NotAuthorized();

        delete _tokenApprovals[tokenId];
        _balances[from] -= 1;
        _balances[to] += 1;
        _owners[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external override {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data)
        public
        override
    {
        transferFrom(from, to, tokenId);
        _checkOnERC721Received(from, to, tokenId, data);
    }

    function royaltyInfo(uint256, uint256 salePrice)
        external
        view
        override
        returns (address receiver, uint256 royaltyAmount)
    {
        receiver = royaltyReceiver;
        royaltyAmount = (salePrice * royaltyBps) / BPS_DENOMINATOR;
    }

    function _isAuthorized(address operator, address tokenOwner, uint256 tokenId)
        private
        view
        returns (bool)
    {
        return operator == tokenOwner || _tokenApprovals[tokenId] == operator
            || _operatorApprovals[tokenOwner][operator];
    }

    function _checkOnERC721Received(address from, address to, uint256 tokenId, bytes memory data)
        private
    {
        if (to.code.length == 0) return;
        try IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data) returns (
            bytes4 selector
        ) {
            if (selector != IERC721Receiver.onERC721Received.selector) revert UnsafeRecipient();
        } catch {
            revert UnsafeRecipient();
        }
    }
}
