# @creditchain/agents

Bounded, revocable spending for AI agents, on CreditChain or any EVM chain.

```ts
import { createPublicClient, createWalletClient, http, parseUnits } from "viem";
import { Mandates, makeReceipt, creditchainArgos } from "@creditchain/agents";

const mandates = new Mandates(createPublicClient({ chain: creditchainArgos, transport: http() }));

// Owner: let an agent spend up to 50 USDC, at most 2 per call, no faster than 10 a day.
const id = await mandates.create(owner, {
  agent: agentAddress, asset: usdc, amount: parseUnits("50", 6),
  perTxMax: parseUnits("2", 6), windowLimit: parseUnits("10", 6), windowSeconds: 86_400,
  maxRelayFee: parseUnits("0.01", 6),
});

// Agent: sign a payment with a receipt of what it buys. The agent's key needs no gas.
const { hash } = makeReceipt({ mandate: `eip155:${chainId}:${mandates.vault}/${id}`, request: { url } });
const auth = { mandateId: id, recipient: api, amount: parseUnits("0.4", 6), receipt: hash,
               fee: parseUnits("0.005", 6), nonce: Mandates.randomNonce(), deadline };
const signature = await mandates.sign(agent, auth);

// Anyone: submit it and collect the fee. The chain checks every limit; nothing outside them moves.
await mandates.relay(relayer, auth, signature);
```

| Export | What |
|---|---|
| `Mandates` | ERC-AGM v2: `create`, `get`, `spendableNow`, `spend`, `sign`, `relay`, `revoke`, `worstCase` |
| `makeReceipt`, `receiptHash`, `canonicalJson` | the `erc-agm-receipt/1` commitment each payment carries (RFC 8785 JSON, keccak256) |
| `QuantumEscape` | register a post-quantum escape key; detect EIP-8355 ML-DSA precompiles |
| `standards`, `canonical` | addresses that are the same on every EVM chain: the vault, the escape registry, x402, Permit2, ERC-4337, ERC-8004 |
| `creditchainArgos` | viem chain for the public testnet |

Tests: `npm test` (receipt vectors always; on-chain flows against a local chain with the
standards deployed — see `test/chain.test.ts`). Not audited; use test assets.
