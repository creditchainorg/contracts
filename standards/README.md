# Standards — one address on every EVM chain

Contracts for AI-agent finance that are meant to run everywhere, not only on CreditChain. Each is
created by the deterministic-deployment proxy (`0x4e59b448…`) with a fixed salt, so the same build
lands at the same address on CreditChain, Base, Ethereum, Arbitrum or any other EVM chain, and
anyone can check that by recomputing it.

| Contract | What it does | Docs |
|---|---|---|
| `AgentMandateVault` | ERC-AGM v2: an owner funds a bounded, revocable spending mandate for an agent, in the native coin or any ERC-20. Signed spends anyone can relay, receipts, key rotation, pause. | [ERC-AGM-v2.md](docs/ERC-AGM-v2.md) |
| `PaidReviews` | Posts ERC-8004 feedback only for customers who paid the agent through x402 and whose money the agent actually claimed. Read `getSummary(agentId, [PaidReviews], …)` to see paying customers only. | NatSpec in the source |
| `QuantumEscapeRegistry` | Any account registers a post-quantum escape key and recovery address while ECDSA is still trustworthy; only that key rotates it afterwards. WOTS+ verified on-chain; ML-DSA through the EIP-8355 precompiles (`0x12`–`0x14`) where a chain has them. | NatSpec in the source |

## Build, test, deploy

```bash
forge build && forge test            # unit, fuzz and invariant tests
forge script script/DeployStandards.s.sol --rpc-url <rpc>                          # prints addresses
forge script script/DeployStandards.s.sol --rpc-url <rpc> --broadcast --account <keystore>
```

`TESTNET=true` points `PaidReviews` at the ERC-8004 testnet registries. The deployment is idempotent.

The compiler settings in `foundry.toml` (solc 0.8.28, cancun, 200 runs, no metadata hash) are part of
every address: change any of them and every address moves.

## Building on the canonical contracts others publish

These contracts compose with third-party contracts that already sit at one address across chains —
x402's payment contracts, Permit2, the ERC-4337 EntryPoint, and ERC-8004's registries. How those get
onto CreditChain, and the proof that they are the same code, is in [`../canonical`](../canonical).

## Status

Not audited. Test assets only until an external audit says otherwise. Licence: MIT OR Apache-2.0
(interfaces CC0), so other chains and wallets can adopt them.
