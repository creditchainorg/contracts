// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.24;

/// The parts of the canonical ERC-8004 registries and x402 batch settlement that PaidReviews reads
/// and calls. Signatures match the reference deployments (ERC-8004 registries v2.0.0 at
/// 0x8004A169…/0x8004BAa1…; x402BatchSettlement at 0x4020074e…0003).

interface IERC8004Identity {
    function ownerOf(uint256 agentId) external view returns (address);
    function getAgentWallet(uint256 agentId) external view returns (address);
    /// Reverts for an agent that does not exist.
    function isAuthorizedOrOwner(address spender, uint256 agentId) external view returns (bool);
}

interface IERC8004Reputation {
    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata tag2,
        string calldata endpoint,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external;
    function revokeFeedback(uint256 agentId, uint64 feedbackIndex) external;
    function getLastIndex(uint256 agentId, address clientAddress) external view returns (uint64);
}

interface IX402BatchSettlement {
    struct ChannelConfig {
        address payer;
        address payerAuthorizer;
        address receiver;
        address receiverAuthorizer;
        address token;
        uint40 withdrawDelay;
        bytes32 salt;
    }

    function getChannelId(ChannelConfig calldata config) external view returns (bytes32);
    function channels(bytes32 channelId)
        external
        view
        returns (uint128 balance, uint128 totalClaimed);
}
