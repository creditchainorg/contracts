// Copyright (c) CreditChain Research Team. All rights reserved.
// SPDX-License-Identifier: CC0-1.0

pragma solidity ^0.8.24;

/// @title IAgentSpendMandate — the ERC-AGM standard interface
/// @notice Canonical interface for a chain-enforced, bounded, revocable
/// spending mandate granted by an owner to an autonomous agent.
///
/// An implementation custodies value on behalf of an owner and lets a delegated
/// `agent` spend it autonomously, while the contract enforces a budget cap, a
/// per-transaction maximum, a rolling-window rate limit, an optional recipient
/// allowlist, and an expiry. The owner can revoke at any time and reclaim the
/// unspent balance. No party other than the mandate's owner may move its funds.
///
/// See ERC-AGM (`docs/standards/ERC-AGM.md`) for the full specification.
/// Reference implementation: `AgentSpendVault.sol`.
interface IAgentSpendMandate {
    /// @dev The full state of a mandate. Implementations MAY store this layout
    /// differently but MUST expose it through `mandate(uint256)`.
    struct Mandate {
        address owner;
        address agent;
        uint256 budget;
        uint256 spent;
        uint256 balance;
        uint256 perTxMax;
        uint256 windowLimit;
        uint64 windowSeconds;
        uint64 windowStart;
        uint256 windowSpent;
        uint64 expiry;
        bool allowlistEnabled;
        bool revoked;
    }

    // ── events ───────────────────────────────────────────────────────────────

    event MandateCreated(
        uint256 indexed mandateId,
        address indexed owner,
        address indexed agent,
        uint256 budget,
        uint256 perTxMax,
        uint256 windowLimit,
        uint64 windowSeconds,
        uint64 expiry,
        bool allowlistEnabled
    );
    event MandateFunded(uint256 indexed mandateId, address indexed from, uint256 amount, uint256 newBalance);
    event RecipientAllowed(uint256 indexed mandateId, address indexed recipient, bool allowed);
    event AgentPayment(
        uint256 indexed mandateId,
        address indexed agent,
        address indexed recipient,
        uint256 amount,
        bytes32 taskRef,
        uint256 totalSpent
    );
    event MandateRevoked(uint256 indexed mandateId, address indexed owner, uint256 refunded);
    event Withdrawn(uint256 indexed mandateId, address indexed owner, uint256 amount);

    // ── errors ───────────────────────────────────────────────────────────────

    error NotOwner();
    error NotAgent();
    error MandateInactive();
    error ZeroAddress();
    error ZeroAmount();
    error BudgetExceeded();
    error PerTxExceeded();
    error WindowExceeded();
    error RecipientNotAllowed();
    error InsufficientBalance();
    error TransferFailed();

    // ── mutating ─────────────────────────────────────────────────────────────

    /// @notice Create and fund a mandate. The value sent becomes its balance.
    /// MUST emit {MandateCreated} (and {MandateFunded} if value > 0).
    function createMandate(
        address agent,
        uint256 budget,
        uint256 perTxMax,
        uint256 windowLimit,
        uint64 windowSeconds,
        uint64 expiry,
        bool allowlistEnabled
    ) external payable returns (uint256 mandateId);

    /// @notice Top up a mandate's balance. Implementations MAY allow anyone to fund.
    function fundMandate(uint256 mandateId) external payable;

    /// @notice Owner sets allowlist membership for a recipient. MUST revert {NotOwner}
    /// for non-owners.
    function allowRecipient(uint256 mandateId, address recipient, bool allowed) external;

    /// @notice The agent spends to a recipient. MUST be callable only by the
    /// mandate's agent and MUST enforce every rail (expiry, allowlist, per-tx,
    /// budget, balance, rolling window), reverting with the corresponding error
    /// and moving no value on violation. MUST emit {AgentPayment} on success.
    function spend(uint256 mandateId, address recipient, uint256 amount, bytes32 taskRef) external;

    /// @notice Owner kill switch: deactivates the mandate and refunds the unspent
    /// balance. After this the agent MUST NOT be able to spend. MUST emit {MandateRevoked}.
    function revoke(uint256 mandateId) external;

    /// @notice Owner reclaims part of the unspent balance without revoking.
    /// MUST emit {Withdrawn}.
    function withdraw(uint256 mandateId, uint256 amount) external;

    // ── views ────────────────────────────────────────────────────────────────

    /// @notice The full mandate record.
    function mandate(uint256 mandateId) external view returns (Mandate memory);

    /// @notice The most the agent could spend right now under all rails combined.
    function spendableNow(uint256 mandateId) external view returns (uint256);

    /// @notice Number of mandates created (also the id of the most recent).
    function mandateCount() external view returns (uint256);

    /// @notice Whether a recipient is allowlisted for a mandate.
    function allowlisted(uint256 mandateId, address recipient) external view returns (bool);
}
