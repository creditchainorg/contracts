Copyright (c) CreditChain Research Team. All rights reserved.

# CreditChain Agent Finance Contracts

This package is the first CreditChain-native protocol wedge for the agentic
finance market.

It is intentionally event-first:

- contracts preserve EVM compatibility;
- CreditChain Browser can index receipts and logs without custom protocol
  changes;
- CreditHouse can deploy and run demo scenarios later;
- protocol objects can mature before any consensus-level native primitive is
  introduced.

## MVP Primitive

`CreditAgentFinance.sol` defines:

- `AgentID`: an on-chain financial identity for an AI agent or controlled
  automated process.
- `SpendPermit`: a policy envelope that defines what an agent may spend.
- `PaymentIntent`: a specific planned payment under a permit.
- `TaskReceipt`: evidence that a task or service was completed.
- `SettlementReceipt`: evidence that a payment intent was settled.
- `CreditObject`: a general financial object such as an invoice, receivable,
  escrow, credit line, loan, collateral claim, or task bounty.

The first demo path is:

```text
AgentRegistered
  -> SpendPermitCreated
  -> PaymentIntentCreated
  -> TaskReceiptRecorded
  -> PaymentSettled
  -> CreditObjectStatusUpdated
```

CreditChain Browser should index these events and explain the lifecycle in
plain language.

## Build / test / deploy

This package is a Foundry project (`foundry.toml`), so the standard tooling
works:

```bash
forge build
forge test
```

To deploy to any CreditChain network listed in
`creditchain/deploy/shared/networks.json`:

```bash
# from the repo root
./deploy/scripts/deploy-agent-finance.sh devnet     # or testnet, local-single, …
```

The wrapper script resolves the RPC URL + chain id from the registry,
sanity-checks the RPC's advertised chain id matches, runs the
[`script/Deploy.s.sol`](script/Deploy.s.sol) Foundry script in a one-shot
`ghcr.io/foundry-rs/foundry` container under the prefunded OpeniBank
operator key, captures the deployed address, and writes it to
`deploy/<network>/secrets/credit-agent-finance.address` so the per-network
Browser indexer can pick it up at boot. See
[`docs/public/getting-started.md` §5](../../docs/public/getting-started.md#5-deploy-the-agent-finance-protocol-operators)
for the full operator walkthrough.

## Status

This is a developer-preview reference contract. It is not audited and should
not be used for production funds. The next phase should add:

- EIP-712 typed signatures;
- ERC-20 settlement adapters;
- policy verification hooks;
- compliance credential hooks;
- dispute and reversal workflows;
- broader test coverage beyond the deploy sanity test.
