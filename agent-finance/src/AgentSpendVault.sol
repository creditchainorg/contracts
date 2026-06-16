// Copyright (c) CreditChain Research Team. All rights reserved.
// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.24;

/// @title AgentSpendVault
/// @notice Programmable, chain-enforced spending authority for AI agents.
///
/// This is the primitive that makes an AI agent a *safe* economic actor:
/// a human (or org) owner funds a vault and delegates a bounded spending
/// mandate to an agent address. The agent can then pay recipients
/// autonomously — no human in the loop per payment — but every rail is
/// enforced by the chain, and the owner keeps an instant kill switch.
///
/// Enforced rails per mandate:
///   - total budget cap (lifetime spend ceiling)
///   - per-transaction maximum (no single payment above the cap)
///   - rolling time-window limit (rate limit, e.g. "max X per day")
///   - optional recipient allowlist (pay only pre-approved addresses)
///   - expiry (mandate auto-stops)
///   - instant owner revocation, which refunds the unspent balance
///
/// Value is native CCC held in the vault. Nothing leaves except through
/// `spend`, gated by the agent's mandate, or `withdraw`/`revoke` by the owner.
///
/// @dev Checks-effects-interactions throughout, plus a reentrancy guard on
/// every value-moving path. No admin can move a mandate's funds except its
/// own owner — there is no global escape hatch over user balances.
contract AgentSpendVault {
    struct Mandate {
        address owner;            // can revoke / withdraw / manage allowlist
        address agent;            // the only address allowed to spend
        uint256 budget;          // total lifetime spend ceiling (wei of CCC)
        uint256 spent;           // cumulative spent
        uint256 balance;         // CCC currently held for this mandate
        uint256 perTxMax;        // max value of a single spend (0 = unlimited)
        uint256 windowLimit;     // max spend within the rolling window (0 = unlimited)
        uint64 windowSeconds;    // length of the rolling window
        uint64 windowStart;      // timestamp the current window opened
        uint256 windowSpent;     // spent within the current window
        uint64 expiry;           // mandate stops at this timestamp (0 = never)
        bool allowlistEnabled;   // if true, recipient must be on the allowlist
        bool revoked;            // owner kill switch
    }

    /// Reentrancy guard states.
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _guard = _NOT_ENTERED;

    uint256 public mandateCount;
    mapping(uint256 => Mandate) private _mandates;
    mapping(uint256 => mapping(address => bool)) public allowlisted;

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
    error Reentrancy();

    modifier nonReentrant() {
        if (_guard == _ENTERED) revert Reentrancy();
        _guard = _ENTERED;
        _;
        _guard = _NOT_ENTERED;
    }

    /// @notice Create and fund a spending mandate for an agent. The CCC sent
    /// with the call becomes the mandate's initial balance.
    /// @param agent The address allowed to spend under this mandate.
    /// @param budget Total lifetime spend ceiling.
    /// @param perTxMax Max value of any single spend (0 = no per-tx cap).
    /// @param windowLimit Max spend per rolling window (0 = no rate limit).
    /// @param windowSeconds Rolling-window length in seconds (ignored if windowLimit==0).
    /// @param expiry Unix time after which the mandate stops (0 = never).
    /// @param allowlistEnabled If true, recipients must be allowlisted to receive.
    function createMandate(
        address agent,
        uint256 budget,
        uint256 perTxMax,
        uint256 windowLimit,
        uint64 windowSeconds,
        uint64 expiry,
        bool allowlistEnabled
    ) external payable returns (uint256 mandateId) {
        if (agent == address(0)) revert ZeroAddress();
        mandateId = ++mandateCount;
        _mandates[mandateId] = Mandate({
            owner: msg.sender,
            agent: agent,
            budget: budget,
            spent: 0,
            balance: msg.value,
            perTxMax: perTxMax,
            windowLimit: windowLimit,
            windowSeconds: windowSeconds,
            windowStart: uint64(block.timestamp),
            windowSpent: 0,
            expiry: expiry,
            allowlistEnabled: allowlistEnabled,
            revoked: false
        });
        emit MandateCreated(
            mandateId, msg.sender, agent, budget, perTxMax, windowLimit, windowSeconds, expiry, allowlistEnabled
        );
        emit MandateFunded(mandateId, msg.sender, msg.value, msg.value);
    }

    /// @notice Top up a mandate's balance. Anyone may fund (e.g. a treasury).
    function fundMandate(uint256 mandateId) external payable {
        Mandate storage m = _mandates[mandateId];
        if (m.owner == address(0)) revert MandateInactive();
        m.balance += msg.value;
        emit MandateFunded(mandateId, msg.sender, msg.value, m.balance);
    }

    /// @notice Owner adds/removes a recipient from this mandate's allowlist.
    function allowRecipient(uint256 mandateId, address recipient, bool allowed) external {
        Mandate storage m = _mandates[mandateId];
        if (msg.sender != m.owner) revert NotOwner();
        if (recipient == address(0)) revert ZeroAddress();
        allowlisted[mandateId][recipient] = allowed;
        emit RecipientAllowed(mandateId, recipient, allowed);
    }

    /// @notice The agent spends from its mandate to a recipient. Every rail is
    /// enforced here; the call reverts (moving nothing) if any rail is violated.
    function spend(uint256 mandateId, address recipient, uint256 amount, bytes32 taskRef)
        external
        nonReentrant
    {
        Mandate storage m = _mandates[mandateId];
        if (msg.sender != m.agent) revert NotAgent();
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (m.revoked) revert MandateInactive();
        if (m.expiry != 0 && block.timestamp > m.expiry) revert MandateInactive();
        if (m.allowlistEnabled && !allowlisted[mandateId][recipient]) revert RecipientNotAllowed();
        if (m.perTxMax != 0 && amount > m.perTxMax) revert PerTxExceeded();
        if (m.budget != 0 && m.spent + amount > m.budget) revert BudgetExceeded();
        if (amount > m.balance) revert InsufficientBalance();

        // Rolling-window rate limit: reset the window if it has elapsed.
        if (m.windowLimit != 0) {
            if (block.timestamp >= m.windowStart + m.windowSeconds) {
                m.windowStart = uint64(block.timestamp);
                m.windowSpent = 0;
            }
            if (m.windowSpent + amount > m.windowLimit) revert WindowExceeded();
            m.windowSpent += amount;
        }

        // Effects before interaction.
        m.spent += amount;
        m.balance -= amount;

        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit AgentPayment(mandateId, m.agent, recipient, amount, taskRef, m.spent);
    }

    /// @notice Owner revokes the mandate (kill switch) and reclaims the unspent
    /// balance. After this the agent can never spend again.
    function revoke(uint256 mandateId) external nonReentrant {
        Mandate storage m = _mandates[mandateId];
        if (msg.sender != m.owner) revert NotOwner();
        m.revoked = true;
        uint256 refund = m.balance;
        m.balance = 0;
        if (refund > 0) {
            (bool ok,) = m.owner.call{value: refund}("");
            if (!ok) revert TransferFailed();
        }
        emit MandateRevoked(mandateId, m.owner, refund);
    }

    /// @notice Owner pulls back part of the unspent balance without revoking.
    function withdraw(uint256 mandateId, uint256 amount) external nonReentrant {
        Mandate storage m = _mandates[mandateId];
        if (msg.sender != m.owner) revert NotOwner();
        if (amount == 0) revert ZeroAmount();
        if (amount > m.balance) revert InsufficientBalance();
        m.balance -= amount;
        (bool ok,) = m.owner.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(mandateId, m.owner, amount);
    }

    // ─────────────────────────── views ───────────────────────────

    function mandate(uint256 mandateId) external view returns (Mandate memory) {
        return _mandates[mandateId];
    }

    /// @notice The most an agent could spend *right now* under all rails,
    /// given balance, remaining budget, and the live rolling window.
    function spendableNow(uint256 mandateId) external view returns (uint256) {
        Mandate storage m = _mandates[mandateId];
        if (m.revoked) return 0;
        if (m.expiry != 0 && block.timestamp > m.expiry) return 0;
        uint256 cap = m.balance;
        if (m.budget != 0) {
            uint256 budgetLeft = m.budget > m.spent ? m.budget - m.spent : 0;
            if (budgetLeft < cap) cap = budgetLeft;
        }
        if (m.windowLimit != 0) {
            uint256 windowLeft;
            if (block.timestamp >= m.windowStart + m.windowSeconds) {
                windowLeft = m.windowLimit; // window would reset on next spend
            } else {
                windowLeft = m.windowLimit > m.windowSpent ? m.windowLimit - m.windowSpent : 0;
            }
            if (windowLeft < cap) cap = windowLeft;
        }
        if (m.perTxMax != 0 && m.perTxMax < cap) cap = m.perTxMax;
        return cap;
    }
}
