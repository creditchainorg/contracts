# CreditChain contracts

Solidity contracts for [CreditChain](https://www.creditchain.org). Each
directory is an independent Foundry project.

| Project | Contents |
|---|---|
| [`agent-finance`](agent-finance) | Agent spend mandates (`AgentSpendVault`), clearing, reputation, NFT market, and a post-quantum break-glass guard, with an end-to-end [demo](agent-finance/demo) against a live chain |
| [`treasury`](treasury) | `Timelock`, `Multisig`, `VestingWallet`, `StakingReserve` — the custody contracts high-value genesis roles resolve to |
| [`hello-creditchain`](hello-creditchain) | Minimal starter for deploying a contract to CreditChain |
| [`standards`](standards) | Contracts deployed at the same address on every EVM chain: ERC-AGM v2 mandates in any asset, payment-backed ERC-8004 reviews, and a post-quantum escape-key registry |
| [`canonical`](canonical) | Init code, proofs and a deploy script for the third-party contracts (x402, Permit2, ERC-4337 EntryPoint) that live at one address on every chain |

## Build and test

```bash
git clone https://github.com/creditchainorg/contracts
cd contracts/agent-finance
forge build && forge test
```

Dependencies are git submodules in `lib/`, shared by every project. Foundry
fetches them on the first build; `git submodule update --init` does the same
by hand.

## Networks

Argos testnet, chain id `2026042404`. RPC endpoints, the faucet, and the
explorer are listed at
[docs.creditchain.org](https://docs.creditchain.org/developers/connect/).
The node client is [creditchainorg/creditchain](https://github.com/creditchainorg/creditchain).

## Status

These contracts are not audited. Test-network CCC has no monetary value.

Report a vulnerability privately to **security@creditchain.org** — see
[`agent-finance/SECURITY.md`](agent-finance/SECURITY.md). Please do not open a
public issue for a security problem.
