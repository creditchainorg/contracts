// Copyright (c) CreditChain Research Team. All rights reserved.
// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.24;

/// @title CreditAgentFinance
/// @notice Event-first MVP for CreditChain agent finance and Credit Objects.
/// @dev This contract is a developer-preview registry. It does not custody funds.
/// `dailyLimit` is descriptive; `totalLimit` bounds each intent, not cumulative spend.
/// Receipts and settlement/status events are authorized claims, not payment proofs.
/// Use a separately reviewed spending vault for enforceable financial mandates.
contract CreditAgentFinance {
    enum CreditObjectType {
        Unknown,
        Invoice,
        Receivable,
        Payable,
        Loan,
        CollateralAgreement,
        Escrow,
        SpendingPermission,
        AgentBudget,
        Subscription,
        TaskBounty,
        SettlementReceipt,
        CreditScoreProof,
        ComplianceCredential,
        MerchantSettlementClaim,
        RwaCashflowClaim
    }

    enum CreditObjectStatus {
        Draft,
        Authorized,
        Funded,
        Active,
        PartiallySettled,
        Settled,
        Defaulted,
        Disputed,
        Resolved,
        Archived
    }

    struct Agent {
        address owner;
        address controller;
        string metadataURI;
        bool active;
    }

    struct SpendPermit {
        bytes32 agentId;
        address issuer;
        address asset;
        uint256 dailyLimit;
        uint256 totalLimit;
        uint64 validAfter;
        uint64 validUntil;
        bytes32 policyHash;
        bool revoked;
        string metadataURI;
    }

    struct PaymentIntent {
        bytes32 permitId;
        bytes32 agentId;
        address merchant;
        address asset;
        uint256 amount;
        bytes32 taskHash;
        bool settled;
        string metadataURI;
    }

    struct CreditObject {
        CreditObjectType objectType;
        CreditObjectStatus status;
        address issuer;
        address counterparty;
        address asset;
        uint256 principal;
        bytes32 termsHash;
        string metadataURI;
    }

    mapping(bytes32 => Agent) public agents;
    mapping(bytes32 => SpendPermit) public spendPermits;
    mapping(bytes32 => PaymentIntent) public paymentIntents;
    mapping(bytes32 => CreditObject) public creditObjects;

    event AgentRegistered(bytes32 indexed agentId, address indexed owner, address indexed controller, string metadataURI);
    event AgentControllerUpdated(bytes32 indexed agentId, address indexed oldController, address indexed newController);
    event SpendPermitCreated(
        bytes32 indexed permitId,
        bytes32 indexed agentId,
        address indexed issuer,
        address asset,
        uint256 dailyLimit,
        uint256 totalLimit,
        uint64 validAfter,
        uint64 validUntil,
        bytes32 policyHash,
        string metadataURI
    );
    event SpendPermitRevoked(bytes32 indexed permitId, bytes32 indexed agentId, address indexed revokedBy, string reason);
    event PaymentIntentCreated(
        bytes32 indexed intentId,
        bytes32 indexed permitId,
        bytes32 indexed agentId,
        address merchant,
        address asset,
        uint256 amount,
        bytes32 taskHash,
        string metadataURI
    );
    event TaskReceiptRecorded(bytes32 indexed receiptId, bytes32 indexed intentId, bytes32 indexed proofHash, string metadataURI);
    event PaymentSettled(bytes32 indexed intentId, bytes32 indexed receiptId, bytes32 indexed settlementHash, string metadataURI);
    event CreditObjectCreated(
        bytes32 indexed objectId,
        CreditObjectType indexed objectType,
        address indexed issuer,
        address counterparty,
        address asset,
        uint256 principal,
        bytes32 termsHash,
        string metadataURI
    );
    event CreditObjectStatusUpdated(
        bytes32 indexed objectId,
        CreditObjectStatus indexed oldStatus,
        CreditObjectStatus indexed newStatus,
        string reason
    );

    modifier onlyAgentOwner(bytes32 agentId) {
        require(agents[agentId].owner == msg.sender, "not agent owner");
        _;
    }

    modifier onlyPermitIssuer(bytes32 permitId) {
        require(spendPermits[permitId].issuer == msg.sender, "not permit issuer");
        _;
    }

    function registerAgent(bytes32 agentId, address controller, string calldata metadataURI) external {
        require(agentId != bytes32(0), "agent id required");
        require(controller != address(0), "controller required");
        require(agents[agentId].owner == address(0), "agent exists");

        agents[agentId] = Agent({
            owner: msg.sender,
            controller: controller,
            metadataURI: metadataURI,
            active: true
        });

        emit AgentRegistered(agentId, msg.sender, controller, metadataURI);
    }

    function updateAgentController(bytes32 agentId, address newController) external onlyAgentOwner(agentId) {
        require(newController != address(0), "controller required");
        address oldController = agents[agentId].controller;
        agents[agentId].controller = newController;
        emit AgentControllerUpdated(agentId, oldController, newController);
    }

    function createSpendPermit(
        bytes32 permitId,
        bytes32 agentId,
        address asset,
        uint256 dailyLimit,
        uint256 totalLimit,
        uint64 validAfter,
        uint64 validUntil,
        bytes32 policyHash,
        string calldata metadataURI
    ) external onlyAgentOwner(agentId) {
        require(permitId != bytes32(0), "permit id required");
        require(spendPermits[permitId].issuer == address(0), "permit exists");
        require(validUntil == 0 || validUntil > validAfter, "invalid validity");
        require(totalLimit == 0 || dailyLimit <= totalLimit, "daily exceeds total");

        spendPermits[permitId] = SpendPermit({
            agentId: agentId,
            issuer: msg.sender,
            asset: asset,
            dailyLimit: dailyLimit,
            totalLimit: totalLimit,
            validAfter: validAfter,
            validUntil: validUntil,
            policyHash: policyHash,
            revoked: false,
            metadataURI: metadataURI
        });

        emit SpendPermitCreated(
            permitId,
            agentId,
            msg.sender,
            asset,
            dailyLimit,
            totalLimit,
            validAfter,
            validUntil,
            policyHash,
            metadataURI
        );
    }

    function revokeSpendPermit(bytes32 permitId, string calldata reason) external onlyPermitIssuer(permitId) {
        SpendPermit storage permit = spendPermits[permitId];
        require(!permit.revoked, "permit revoked");
        permit.revoked = true;
        emit SpendPermitRevoked(permitId, permit.agentId, msg.sender, reason);
    }

    function createPaymentIntent(
        bytes32 intentId,
        bytes32 permitId,
        address merchant,
        uint256 amount,
        bytes32 taskHash,
        string calldata metadataURI
    ) external {
        SpendPermit storage permit = spendPermits[permitId];
        Agent storage agent = agents[permit.agentId];

        require(intentId != bytes32(0), "intent id required");
        require(paymentIntents[intentId].permitId == bytes32(0), "intent exists");
        require(agent.controller == msg.sender || agent.owner == msg.sender, "not authorized");
        require(!permit.revoked, "permit revoked");
        require(block.timestamp >= permit.validAfter, "permit not active");
        require(permit.validUntil == 0 || block.timestamp <= permit.validUntil, "permit expired");
        require(permit.totalLimit == 0 || amount <= permit.totalLimit, "amount exceeds permit");

        paymentIntents[intentId] = PaymentIntent({
            permitId: permitId,
            agentId: permit.agentId,
            merchant: merchant,
            asset: permit.asset,
            amount: amount,
            taskHash: taskHash,
            settled: false,
            metadataURI: metadataURI
        });

        emit PaymentIntentCreated(
            intentId,
            permitId,
            permit.agentId,
            merchant,
            permit.asset,
            amount,
            taskHash,
            metadataURI
        );
    }

    function recordTaskReceipt(
        bytes32 receiptId,
        bytes32 intentId,
        bytes32 proofHash,
        string calldata metadataURI
    ) external {
        PaymentIntent storage intent = paymentIntents[intentId];
        Agent storage agent = agents[intent.agentId];

        require(intent.permitId != bytes32(0), "intent missing");
        require(agent.controller == msg.sender || agent.owner == msg.sender || intent.merchant == msg.sender, "not authorized");

        emit TaskReceiptRecorded(receiptId, intentId, proofHash, metadataURI);
    }

    function settlePaymentIntent(
        bytes32 intentId,
        bytes32 receiptId,
        bytes32 settlementHash,
        string calldata metadataURI
    ) external {
        PaymentIntent storage intent = paymentIntents[intentId];
        Agent storage agent = agents[intent.agentId];

        require(intent.permitId != bytes32(0), "intent missing");
        require(!intent.settled, "already settled");
        require(agent.controller == msg.sender || agent.owner == msg.sender || intent.merchant == msg.sender, "not authorized");

        intent.settled = true;
        emit PaymentSettled(intentId, receiptId, settlementHash, metadataURI);
    }

    function createCreditObject(
        bytes32 objectId,
        CreditObjectType objectType,
        address counterparty,
        address asset,
        uint256 principal,
        bytes32 termsHash,
        string calldata metadataURI
    ) external {
        require(objectId != bytes32(0), "object id required");
        require(creditObjects[objectId].issuer == address(0), "object exists");
        require(objectType != CreditObjectType.Unknown, "object type required");

        creditObjects[objectId] = CreditObject({
            objectType: objectType,
            status: CreditObjectStatus.Draft,
            issuer: msg.sender,
            counterparty: counterparty,
            asset: asset,
            principal: principal,
            termsHash: termsHash,
            metadataURI: metadataURI
        });

        emit CreditObjectCreated(
            objectId,
            objectType,
            msg.sender,
            counterparty,
            asset,
            principal,
            termsHash,
            metadataURI
        );
    }

    function updateCreditObjectStatus(
        bytes32 objectId,
        CreditObjectStatus newStatus,
        string calldata reason
    ) external {
        CreditObject storage creditObject = creditObjects[objectId];
        require(creditObject.issuer == msg.sender, "not issuer");

        CreditObjectStatus oldStatus = creditObject.status;
        creditObject.status = newStatus;

        emit CreditObjectStatusUpdated(objectId, oldStatus, newStatus, reason);
    }
}
