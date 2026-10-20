// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import { IERC8004Identity, IERC8004Reputation, IX402BatchSettlement } from "./External.sol";

/// @title PaidReviews — ERC-8004 feedback from customers who provably paid
/// @notice ERC-8004 lets anyone review any agent, so its own security section asks readers to
///         filter reviews by reviewer. This contract is a reviewer worth filtering by: it posts a
///         review to the canonical ERC-8004 reputation registry only for a caller who paid that
///         agent through an x402 payment channel, and only once the agent's side has claimed money
///         from that channel. Reading
///
///             getSummary(agentId, [address(PaidReviews)], tag1, tag2)
///
///         on the registry then summarises paying customers only.
///
/// What it rules out: reviews from nobody (no payment), reviews before the agent took any money,
/// two reviews from one channel, and reviews by the agent's own owner, operators or wallet.
///
/// What it cannot rule out, stated plainly: an agent's operator paying itself from an address
/// nobody has linked to it. That costs real capital locked in a channel for its withdraw delay,
/// plus gas, and every review links to the channel it rests on, so circular payment is visible to
/// anyone who indexes the channel graph. Paid reviews are evidence, not proof of independence.
///
/// @dev No owner, no upgrade, no funds held. One deployment per (identity, reputation, x402)
///      triple; on mainnets those three are canonical, so this contract's address is too.
///
///      SECURITY STATUS: not yet audited.
contract PaidReviews {
    IERC8004Identity public immutable identity;
    IERC8004Reputation public immutable reputation;
    IX402BatchSettlement public immutable settlement;

    struct Review {
        int128 value;
        uint8 valueDecimals;
        string tag1;
        string tag2;
        string endpoint;
        string feedbackURI;
        bytes32 feedbackHash;
    }

    /// channelId => already used for a review.
    mapping(bytes32 => bool) public reviewed;
    /// agentId => feedbackIndex => who wrote it (only they may revoke it).
    mapping(uint256 => mapping(uint64 => address)) public reviewer;

    event PaidReview(
        uint256 indexed agentId,
        address indexed payer,
        bytes32 indexed channelId,
        address token,
        uint256 amountPaid,
        uint64 feedbackIndex
    );
    event PaidReviewRevoked(uint256 indexed agentId, address indexed payer, uint64 feedbackIndex);

    error NotPayer();
    error NotAgentReceiver();
    error SelfReview();
    error NothingClaimed();
    error AlreadyReviewed();
    error NotReviewer();
    error ZeroAddress();

    constructor(
        IERC8004Identity identity_,
        IERC8004Reputation reputation_,
        IX402BatchSettlement settlement_
    ) {
        if (
            address(identity_) == address(0) || address(reputation_) == address(0)
                || address(settlement_) == address(0)
        ) revert ZeroAddress();
        identity = identity_;
        reputation = reputation_;
        settlement = settlement_;
    }

    /// @notice Review `agentId` on the strength of the x402 channel described by `config`.
    /// @dev The caller must be the channel's payer or its payer authorizer; the channel's receiver
    ///      must be the agent's verified payment wallet or its owner; the agent's side must have
    ///      claimed a non-zero amount. One review per channel.
    function reviewX402(
        uint256 agentId,
        IX402BatchSettlement.ChannelConfig calldata config,
        Review calldata r
    ) external returns (uint64 feedbackIndex) {
        (bytes32 channelId, uint128 claimed) = _checkChannel(agentId, config);
        reviewed[channelId] = true;
        feedbackIndex = _post(agentId, r);
        reviewer[agentId][feedbackIndex] = msg.sender;
        emit PaidReview(agentId, config.payer, channelId, config.token, claimed, feedbackIndex);
    }

    /// Who may review, about whom, on the strength of which channel.
    function _checkChannel(uint256 agentId, IX402BatchSettlement.ChannelConfig calldata config)
        private
        view
        returns (bytes32 channelId, uint128 claimed)
    {
        address payer = config.payer;
        if (
            msg.sender != payer
                && (config.payerAuthorizer == address(0) || msg.sender != config.payerAuthorizer)
        ) {
            revert NotPayer();
        }

        // Also reverts if the agent does not exist.
        if (identity.isAuthorizedOrOwner(payer, agentId)) revert SelfReview();
        if (msg.sender != payer && identity.isAuthorizedOrOwner(msg.sender, agentId)) {
            revert SelfReview();
        }
        address wallet = identity.getAgentWallet(agentId);
        if (payer == wallet || msg.sender == wallet) revert SelfReview();
        address receiver = config.receiver;
        if (receiver == address(0) || (receiver != wallet && receiver != identity.ownerOf(agentId)))
        {
            revert NotAgentReceiver();
        }

        channelId = settlement.getChannelId(config);
        if (reviewed[channelId]) revert AlreadyReviewed();
        (, claimed) = settlement.channels(channelId);
        if (claimed == 0) revert NothingClaimed();
    }

    function _post(uint256 agentId, Review calldata r) private returns (uint64) {
        reputation.giveFeedback(
            agentId,
            r.value,
            r.valueDecimals,
            r.tag1,
            r.tag2,
            r.endpoint,
            r.feedbackURI,
            r.feedbackHash
        );
        return reputation.getLastIndex(agentId, address(this));
    }

    /// @notice The reviewer withdraws their review. The channel stays used: a payer gets one say
    ///         per channel, not one per attempt.
    function revoke(uint256 agentId, uint64 feedbackIndex) external {
        if (reviewer[agentId][feedbackIndex] != msg.sender || msg.sender == address(0)) {
            revert NotReviewer();
        }
        reputation.revokeFeedback(agentId, feedbackIndex);
        emit PaidReviewRevoked(agentId, msg.sender, feedbackIndex);
    }
}
