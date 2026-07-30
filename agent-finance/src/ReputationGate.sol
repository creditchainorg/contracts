// Copyright (c) CreditChain Research Team. All rights reserved.
// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.24;

import {IAgentSpendMandate} from "./IAgentSpendMandate.sol";
import {AgentReputation} from "./AgentReputation.sol";

/// @title ReputationGate
/// @notice Reputation-gated agent spending — "reputation becomes collateral"
/// made enforceable. This closes the loop between the two CreditChain
/// agent-finance primitives: `AgentSpendVault` bounds *how much* an agent may
/// spend, and `AgentReputation` records *what it has provably done*. This
/// contract makes the second a precondition of the first.
///
/// How it composes without touching either deployed contract: the owner creates
/// a mandate in the vault whose `agent` is **this gate**, then registers an
/// operator (the real agent) plus a minimum reputation score. The operator
/// spends via {spendVia}, which checks reputation and forwards to the vault —
/// so the vault's own rails (budget, per-tx, window, allowlist, expiry, revoke)
/// still apply underneath, unchanged and unweakened.
///
/// The result: an agent must *earn* the right to spend, and keeps it only while
/// its on-chain record holds. An owner can raise the bar at any time, and the
/// vault owner's instant revoke remains the ultimate kill switch.
///
/// @dev This gate holds no funds of its own. It is a pure authorisation layer;
/// all value stays in the vault until the vault itself releases it.
contract ReputationGate {
    IAgentSpendMandate public immutable vault;
    AgentReputation public immutable reputation;

    struct Policy {
        address owner;       // who configured this gate entry (the mandate owner)
        address operator;    // the real agent permitted to spend
        uint256 minScore;    // required AgentReputation.score(operator)
        bool enabled;        // owner can disable without touching the vault
    }

    /// mandateId => policy
    mapping(uint256 => Policy) private _policies;

    event PolicySet(
        uint256 indexed mandateId,
        address indexed owner,
        address indexed operator,
        uint256 minScore
    );
    event PolicyDisabled(uint256 indexed mandateId, address indexed owner);
    event GatedSpend(
        uint256 indexed mandateId,
        address indexed operator,
        address indexed recipient,
        uint256 amount,
        uint256 operatorScore
    );

    error NotMandateOwner();
    error NotOperator();
    error PolicyNotEnabled();
    error InsufficientReputation(uint256 score, uint256 required);
    error ZeroAddress();
    error GateNotMandateAgent();

    constructor(address vault_, address reputation_) {
        if (vault_ == address(0) || reputation_ == address(0)) revert ZeroAddress();
        vault = IAgentSpendMandate(vault_);
        reputation = AgentReputation(reputation_);
    }

    /// @notice Mandate owner authorises `operator` to spend from `mandateId`
    /// once its reputation score reaches `minScore`. Re-callable to raise or
    /// lower the bar, or to rotate the operator.
    /// @dev Requires that this gate is actually the mandate's agent, otherwise
    /// the policy could never be exercised and would be misleading on-chain.
    function setPolicy(uint256 mandateId, address operator, uint256 minScore) external {
        if (operator == address(0)) revert ZeroAddress();
        IAgentSpendMandate.Mandate memory m = vault.mandate(mandateId);
        if (msg.sender != m.owner) revert NotMandateOwner();
        if (m.agent != address(this)) revert GateNotMandateAgent();

        _policies[mandateId] = Policy({
            owner: msg.sender,
            operator: operator,
            minScore: minScore,
            enabled: true
        });
        emit PolicySet(mandateId, msg.sender, operator, minScore);
    }

    /// @notice Owner disables the gate entry. The vault mandate is untouched —
    /// use the vault's own `revoke` to reclaim funds.
    function disablePolicy(uint256 mandateId) external {
        Policy storage p = _policies[mandateId];
        if (msg.sender != p.owner) revert NotMandateOwner();
        p.enabled = false;
        emit PolicyDisabled(mandateId, msg.sender);
    }

    /// @notice The operator spends through the gate. Reputation is checked at
    /// call time — an agent that has not yet earned its score cannot spend, and
    /// a raised bar takes effect immediately.
    function spendVia(uint256 mandateId, address recipient, uint256 amount, bytes32 taskRef)
        external
    {
        Policy storage p = _policies[mandateId];
        if (!p.enabled) revert PolicyNotEnabled();
        if (msg.sender != p.operator) revert NotOperator();

        uint256 score = reputation.score(msg.sender);
        if (score < p.minScore) revert InsufficientReputation(score, p.minScore);

        // The vault re-checks every rail; this gate only adds a precondition.
        vault.spend(mandateId, recipient, amount, taskRef);
        emit GatedSpend(mandateId, msg.sender, recipient, amount, score);
    }

    // ─────────────────────────── views ───────────────────────────

    function policy(uint256 mandateId) external view returns (Policy memory) {
        return _policies[mandateId];
    }

    /// @notice Whether `operator` currently satisfies the gate for `mandateId`.
    /// Useful for wallets/UIs to show "eligible" before a call is attempted.
    function isEligible(uint256 mandateId, address operator) external view returns (bool) {
        Policy storage p = _policies[mandateId];
        return p.enabled && p.operator == operator && reputation.score(operator) >= p.minScore;
    }
}
