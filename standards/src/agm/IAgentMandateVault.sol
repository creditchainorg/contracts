// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/// @title IAgentMandateVault — ERC-AGM v2
/// @notice A chain-enforced, bounded, revocable spending mandate that an owner grants to an
///         autonomous agent, for the chain's native coin or any ERC-20.
///
/// v2 keeps v1's rails and kill switch, and adds what an agent needs on chains other than
/// CreditChain and at production volume:
///   - any asset: a mandate holds the native coin (`asset == address(0)`) or one ERC-20, so an
///     agent on Base can be bounded in USDC exactly as an agent on CreditChain is bounded in CCC;
///   - signed spends: the agent signs (EIP-712; ECDSA or ERC-1271) and anyone relays, taking a fee
///     the owner capped — so the agent's key never has to hold gas, or anything else of value;
///   - receipts: every payment carries a 32-byte commitment to what it paid for;
///   - an owner can rotate a compromised agent key, or pause, without losing the mandate's history.
///
/// `AgentPayment`, `MandateRevoked` and `Withdrawn` keep their v1 signatures, so an indexer that
/// reads v1 payments reads v2 payments too.
interface IAgentMandateVault {
    /// @notice A mandate as callers see it. Amounts are in the mandate's asset's smallest unit.
    struct Mandate {
        address owner;
        address agent;
        /// address(0) = the chain's native coin; otherwise an ERC-20.
        address asset;
        /// Lifetime ceiling on everything that leaves for the agent: payments plus relay fees.
        /// 0 = no ceiling.
        uint256 budget;
        uint256 spent;
        uint256 balance;
        /// Ceiling on a single payment (relay fees excluded). 0 = no ceiling.
        uint256 perTxMax;
        /// Ceiling on payments plus fees per rolling window. 0 = no window.
        uint256 windowLimit;
        uint64 windowSeconds;
        uint64 windowStart;
        uint256 windowSpent;
        /// Ceiling on the fee a relayer may take for one signed spend. 0 = relays must be free.
        uint256 maxRelayFee;
        /// Paid to the mandate's own owner. Reputation built on this mandate should exclude it:
        /// paying yourself through your own agent is not work.
        uint256 spentToOwner;
        /// The mandate stops after this time. 0 = never.
        uint64 expiry;
        bool allowlistEnabled;
        bool paused;
        bool revoked;
    }

    /// @notice Terms for a new mandate. `amount` is the initial funding: equal to msg.value for the
    ///         native coin, pulled with transferFrom for an ERC-20.
    struct MandateTerms {
        address agent;
        address asset;
        uint256 amount;
        uint256 budget;
        uint256 perTxMax;
        uint256 windowLimit;
        uint64 windowSeconds;
        uint64 expiry;
        bool allowlistEnabled;
        uint256 maxRelayFee;
    }

    /// @notice What an agent signs to spend without sending a transaction itself.
    /// @dev EIP-712 type:
    ///      SpendAuthorization(uint256 mandateId,address recipient,uint256 amount,bytes32 receipt,
    ///                         uint256 fee,uint256 nonce,uint256 deadline)
    ///      Nonces are unordered (any unused value works once), so an agent can sign many
    ///      payments concurrently.
    struct SpendAuthorization {
        uint256 mandateId;
        address recipient;
        uint256 amount;
        bytes32 receipt;
        uint256 fee;
        uint256 nonce;
        uint256 deadline;
    }

    event MandateCreated(
        uint256 indexed mandateId,
        address indexed owner,
        address indexed agent,
        address asset,
        uint256 budget,
        uint256 perTxMax,
        uint256 windowLimit,
        uint64 windowSeconds,
        uint64 expiry,
        bool allowlistEnabled,
        uint256 maxRelayFee
    );
    event MandateFunded(
        uint256 indexed mandateId, address indexed from, uint256 amount, uint256 newBalance
    );
    event RecipientAllowed(uint256 indexed mandateId, address indexed recipient, bool allowed);
    /// @dev Same signature as ERC-AGM v1. `taskRef` is the receipt commitment.
    event AgentPayment(
        uint256 indexed mandateId,
        address indexed agent,
        address indexed recipient,
        uint256 amount,
        bytes32 taskRef,
        uint256 totalSpent
    );
    event RelayFeePaid(
        uint256 indexed mandateId, address indexed relayer, uint256 fee, uint256 nonce
    );
    event AgentRotated(
        uint256 indexed mandateId, address indexed previousAgent, address indexed agent
    );
    event MandatePaused(uint256 indexed mandateId, bool paused);
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
    error FeeExceedsCap();
    error SignatureExpired();
    error NonceUsed();
    error BadSignature();
    error WrongValue();
    error AmountTooLarge();
    error Reentrancy();

    function createMandate(MandateTerms calldata terms) external payable returns (uint256 mandateId);
    function fund(uint256 mandateId, uint256 amount) external payable;
    function allowRecipient(uint256 mandateId, address recipient, bool allowed) external;
    function spend(uint256 mandateId, address recipient, uint256 amount, bytes32 receipt) external;
    function spendWithSignature(SpendAuthorization calldata auth, bytes calldata signature) external;
    function rotateAgent(uint256 mandateId, address agent) external;
    function setPaused(uint256 mandateId, bool paused) external;
    function revoke(uint256 mandateId) external;
    function withdraw(uint256 mandateId, uint256 amount) external;

    function mandate(uint256 mandateId) external view returns (Mandate memory);
    function spendableNow(uint256 mandateId) external view returns (uint256);
    function mandateCount() external view returns (uint256);
    function allowlisted(uint256 mandateId, address recipient) external view returns (bool);
    function nonceUsed(uint256 mandateId, uint256 nonce) external view returns (bool);
    function spendDigest(SpendAuthorization calldata auth) external view returns (bytes32);
}
