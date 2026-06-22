// Copyright (c) CreditChain Research Team. All rights reserved.
// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.24;

import {IAgentSpendMandate} from "./IAgentSpendMandate.sol";

/// @title AgentReputation
/// @notice On-chain, mandate-backed reputation for AI agents — the substrate for
/// "reputation becomes collateral" (agents that have provably served real
/// spending mandates can earn larger ones).
///
/// Reputation is built **only** from real `AgentSpendVault` mandates:
///   - the attester must be the mandate's actual owner,
///   - the mandate must have settled spend (`spent > 0`),
///   - each mandate can be attested at most once.
///
/// So an agent's record cannot be faked by spamming a counter — every point is
/// backed by value the agent actually moved under a human-granted mandate,
/// verified against the vault at attestation time.
///
/// @dev v1 is a pure registry (holds no funds). It is intentionally simple: it
/// records *what happened* on-chain. Sybil-resistance of the *attesters* (e.g.
/// weighting by the attester's own stake/reputation) is a consumer concern and
/// a future extension; consumers may also read the raw fields and compute their
/// own score rather than trust `score()`.
contract AgentReputation {
    /// The AgentSpendVault (ERC-AGM) this registry draws mandate facts from.
    IAgentSpendMandate public immutable vault;

    struct Reputation {
        uint256 mandatesServed; // distinct mandates the agent settled spend under
        uint256 valueSettled;   // cumulative CCC (wei) settled across those mandates
        uint64 firstSeen;       // timestamp of first attestation
        uint64 lastActivity;    // timestamp of latest attestation
    }

    mapping(address => Reputation) private _rep;
    /// mandateId => attested, so each mandate contributes at most once.
    mapping(uint256 => bool) public attestedMandate;

    event AgentAttested(
        address indexed agent,
        address indexed owner,
        uint256 indexed mandateId,
        uint256 settled,
        uint256 totalValueSettled,
        uint256 mandatesServed
    );

    error NotMandateOwner();
    error NoSettledSpend();
    error AlreadyAttested();
    error ZeroVault();

    constructor(address vault_) {
        if (vault_ == address(0)) revert ZeroVault();
        vault = IAgentSpendMandate(vault_);
    }

    /// @notice The owner of a vault mandate attests its agent's completed work.
    /// Pulls the mandate from the vault, checks caller is the owner and that the
    /// agent actually spent, and credits the agent's reputation once per mandate.
    function attestMandate(uint256 mandateId) external {
        if (attestedMandate[mandateId]) revert AlreadyAttested();

        IAgentSpendMandate.Mandate memory m = vault.mandate(mandateId);
        if (msg.sender != m.owner) revert NotMandateOwner();
        if (m.spent == 0) revert NoSettledSpend();

        attestedMandate[mandateId] = true;

        Reputation storage r = _rep[m.agent];
        if (r.firstSeen == 0) r.firstSeen = uint64(block.timestamp);
        r.mandatesServed += 1;
        r.valueSettled += m.spent;
        r.lastActivity = uint64(block.timestamp);

        emit AgentAttested(m.agent, m.owner, mandateId, m.spent, r.valueSettled, r.mandatesServed);
    }

    // ─────────────────────────── views ───────────────────────────

    function reputation(address agent) external view returns (Reputation memory) {
        return _rep[agent];
    }

    /// @notice A naive, monotonic reputation score: 100 points per mandate served
    /// plus one point per whole CCC settled. Provided for convenience; consumers
    /// that need different weighting should read `reputation()` and compute their
    /// own. Never decreases as an agent does more verified work.
    function score(address agent) external view returns (uint256) {
        Reputation storage r = _rep[agent];
        return r.mandatesServed * 100 + r.valueSettled / 1e18;
    }
}
