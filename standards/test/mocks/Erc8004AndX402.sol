// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import { IX402BatchSettlement } from "../../src/reputation/External.sol";

/// Behaves like the ERC-8004 reference IdentityRegistry for the calls PaidReviews makes:
/// ownerOf reverts for unknown agents, operators count as authorised, agentWallet defaults to
/// the owner and is cleared on transfer.
contract MockIdentity {
    mapping(uint256 => address) public owners;
    mapping(uint256 => address) public wallets;
    mapping(uint256 => mapping(address => bool)) public operators;
    uint256 public next;

    function register(address owner) external returns (uint256 id) {
        id = ++next;
        owners[id] = owner;
        wallets[id] = owner;
    }

    function setWallet(uint256 id, address w) external {
        wallets[id] = w;
    }

    function approve(uint256 id, address op) external {
        operators[id][op] = true;
    }

    function ownerOf(uint256 id) public view returns (address o) {
        o = owners[id];
        require(o != address(0), "ERC721NonexistentToken");
    }

    function getAgentWallet(uint256 id) external view returns (address) {
        return wallets[id];
    }

    function isAuthorizedOrOwner(address spender, uint256 id) external view returns (bool) {
        address o = ownerOf(id);
        return spender == o || operators[id][spender];
    }
}

/// Behaves like the ERC-8004 reference ReputationRegistry: rejects self-feedback, 1-indexed
/// per-client counters, revocation by the client that gave the feedback.
contract MockReputation {
    MockIdentity public immutable identity;
    mapping(uint256 => mapping(address => uint64)) public getLastIndex;
    mapping(uint256 => mapping(address => mapping(uint64 => int128))) public values;
    mapping(uint256 => mapping(address => mapping(uint64 => bool))) public revoked;

    constructor(MockIdentity id) {
        identity = id;
    }

    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata,
        string calldata,
        string calldata,
        string calldata,
        bytes32
    ) external {
        require(valueDecimals <= 18, "too many decimals");
        require(!identity.isAuthorizedOrOwner(msg.sender, agentId), "Self-feedback not allowed");
        uint64 i = ++getLastIndex[agentId][msg.sender];
        values[agentId][msg.sender][i] = value;
    }

    function revokeFeedback(uint256 agentId, uint64 i) external {
        require(i > 0 && i <= getLastIndex[agentId][msg.sender], "index out of bounds");
        require(!revoked[agentId][msg.sender][i], "Already revoked");
        revoked[agentId][msg.sender][i] = true;
    }
}

/// The two views of x402BatchSettlement PaidReviews reads. The id is an EIP-712 hash bound to
/// chain and contract, as in the reference.
contract MockSettlement {
    mapping(bytes32 => uint128) public balanceOf;
    mapping(bytes32 => uint128) public claimedOf;

    bytes32 constant CHANNEL_CONFIG_TYPEHASH = keccak256(
        "ChannelConfig(address payer,address payerAuthorizer,address receiver,address receiverAuthorizer,address token,uint40 withdrawDelay,bytes32 salt)"
    );

    function getChannelId(IX402BatchSettlement.ChannelConfig calldata c)
        public
        view
        returns (bytes32)
    {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("x402 Batch Settlement"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
        return keccak256(
            abi.encodePacked("\x19\x01", domain, keccak256(abi.encode(CHANNEL_CONFIG_TYPEHASH, c)))
        );
    }

    function set(IX402BatchSettlement.ChannelConfig calldata c, uint128 balance, uint128 claimed)
        external
    {
        bytes32 id = getChannelId(c);
        balanceOf[id] = balance;
        claimedOf[id] = claimed;
    }

    function channels(bytes32 id) external view returns (uint128, uint128) {
        return (balanceOf[id], claimedOf[id]);
    }
}
