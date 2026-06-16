# Agent Commerce Demo — the loop nobody else can run

This is the flagship proof of CreditChain's thesis: an **AI agent that spends
autonomously while the chain enforces every limit a human set.** It runs
against a live `creditchaind` node with real CCC. No payment in this demo is
approved by a human — each one is allowed or rejected by the deployed
[`AgentSpendVault`](../src/AgentSpendVault.sol) contract itself.

## What it proves, on-chain

1. **Grant, not custody.** The owner funds a vault and grants the agent a
   bounded mandate (budget 5 CCC · per-tx ≤ 2 CCC · recipient allowlist · the
   agent gets only a 0.05 CCC *gas* stipend, never the spending funds).
2. **Autonomous spend.** The agent pays a metered "API provider" per task with
   no human in the loop — real value moves on real blocks.
3. **The chain holds the rails.** Three out-of-bounds payments are rejected by
   the contract, by name: `PerTxExceeded()`, `BudgetExceeded()`,
   `RecipientNotAllowed()` — and a valid in-budget payment still succeeds.
4. **Kill switch.** The owner revokes; the unspent balance is refunded and any
   further agent payment reverts with `MandateInactive()`.

`SAMPLE-RUN.txt` is a captured run. Yours will differ only in addresses.

## Run it

```bash
# 1. Have a node up (devnet default). e.g. the local devnet on :8545
# 2. forge + cast on PATH (~/.foundry/bin)
cd contracts/agent-finance/demo
RPC_URL=http://localhost:8545 ./agent_commerce_demo.sh
```

Environment (all optional):

| Var | Default | Meaning |
|---|---|---|
| `RPC_URL` | `http://localhost:8545` | JSON-RPC endpoint |
| `OWNER_KEY` | devnet `deploy/devnet/secrets/faucet.key` | funded owner/deployer key |
| `VAULT` | *(deploys a fresh one)* | reuse an already-deployed vault |

Against the **public testnet**, point `RPC_URL` at the testnet RPC and set
`OWNER_KEY` to a faucet-funded key. The same script then writes the same proof
onto a public explorer — which is exactly the viral hook in
[`../../../AI-FINANCE-THESIS.md`](../../../AI-FINANCE-THESIS.md) §4.

## Why this is the moat

Every other chain's security model is "the key is the user." The moment the
user is software, they force a false choice: hand the agent your keys
(catastrophic) or keep a human approving every payment (defeats autonomy).
CreditChain makes the *bounded mandate* a first-class, chain-enforced object —
so the agent is autonomous **and** safe. This demo is that claim, executed.
