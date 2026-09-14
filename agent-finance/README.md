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
works. Its dependencies are git submodules in the repository's top-level
`lib/`; Foundry fetches them on the first build.

```bash
forge build
forge test
```

To deploy, check that the RPC is the network you mean, then run the
[`script/Deploy.s.sol`](script/Deploy.s.sol) Foundry script with a key you
funded yourself:

```bash
cast chain-id --rpc-url testnet          # 2026042404 = Argos testnet
forge script script/Deploy.s.sol:Deploy \
    --rpc-url testnet \
    --private-key "$PRIVATE_KEY" \
    --broadcast
```

The script prints the deployed address, chain id, and deployer. Network
details, the faucet, and the explorer are listed at
[docs.creditchain.org](https://docs.creditchain.org/developers/connect/).

## Status

This is a developer-preview reference contract. It is not audited and should
not be used for production funds. The next phase should add:

- EIP-712 typed signatures;
- ERC-20 settlement adapters;
- policy verification hooks;
- compliance credential hooks;
- dispute and reversal workflows;
- broader test coverage beyond the deploy sanity test.
