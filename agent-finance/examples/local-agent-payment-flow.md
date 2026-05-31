Copyright (c) CreditChain Research Team. All rights reserved.

# Local Agent Payment Flow

This is the first CreditChain market demo sequence. It intentionally uses
hashes and metadata URIs so that off-chain AI/operator systems can attach rich
evidence while the chain records compact, auditable financial state.

## Scenario

An OpeniBank-controlled agent is allowed to spend up to a fixed budget on a paid
MCP/API task. The agent creates a payment intent, records proof that the task
was completed, settles the payment, and leaves a browser-indexable audit trail.

## Flow

1. Register the agent:

```solidity
registerAgent(agentId, controller, "ipfs://agent-metadata")
```

2. Create a policy-bound permit:

```solidity
createSpendPermit(
  permitId,
  agentId,
  IUSD,
  100e18,
  500e18,
  validAfter,
  validUntil,
  policyHash,
  "ipfs://permit-policy"
)
```

3. Agent creates intent:

```solidity
createPaymentIntent(
  intentId,
  permitId,
  merchant,
  12e18,
  taskHash,
  "ipfs://payment-intent"
)
```

4. Agent or merchant records task receipt:

```solidity
recordTaskReceipt(receiptId, intentId, proofHash, "ipfs://task-receipt")
```

5. Authorized party settles:

```solidity
settlePaymentIntent(intentId, receiptId, settlementHash, "ipfs://settlement")
```

6. Browser explains:

```text
This agent spent 12 IUSD under permit P, for task T, within policy limits.
The task receipt and settlement receipt were both recorded. No dispute or
default event has been indexed.
```
