# AgentSpendVault — proven live on the public CreditChain testnet

This records a real run of the agent-commerce loop on the **public testnet**
(chainId `2026042404`), not a local devnet. Hostnames are redacted to
`<DOMAIN>` per repo policy; chain IDs, addresses, and tx hashes are public
testnet artifacts (test CCC has no monetary value).

## Chain state at run time

| Network | chainId | head (≈) | peers | gas price |
|---|---|---|---|---|
| devnet  | 2026042403 | 118,945 | solo dev-mine | 7 wei |
| testnet | 2026042404 | 79,367 | 2 | 7 wei |

Both producing blocks at ~1s freshness.

## What ran (deployed + exercised on testnet)

`AgentSpendVault` deployed to testnet and the full mandate loop executed by an
autonomous agent. The owner approved **no individual payment**; the contract
allowed or rejected each one.

- **Vault:** `0x71C95911E9a5D330f4D621842EC243EE1343292e` (bytecode 5,906 bytes on-chain)
- **Creator/owner:** `0x70997970C51812dc3A010C7d01b50e0d17dc79C8`
- **Creation tx:** `0x35c49d536f2cd8ae7800608136e38873afe00a2dc9d8bd455f461d4497ebc79d`
- **Mandate:** budget 5 CCC · per-tx ≤ 2 CCC · recipient allowlist ON · funded 5 CCC

### Autonomous agent payments (on-chain `AgentPayment` events)

| Block | Task | Amount | Tx hash |
|---|---|---|---|
| 79372 | image-embed-001 | 2 CCC | `0x7e201a25cd19b33a88db0f25af63944021773dd8ff5af7abe27501ee6b0ec8e5` |
| 79373 | image-embed-002 | 2 CCC | `0x162b8465609694026aef126b08e8d3b63ee03f3feab7bdb960e54d8b52f8c1c9` |
| 79374 | image-embed-003 | 1 CCC | `0xe4489e9943d5c0304e4b3093d3efa0c1d89f1b70af5772eb8e2bf23085139630` |

Method id on each: `0x04e27571` = `spend(uint256,address,bytes32,uint256)`.

### Rails the chain enforced (rejected, nothing moved)

- 3 CCC single payment → `PerTxExceeded()`
- 2 CCC over remaining 1 CCC budget → `BudgetExceeded()`
- payment to a non-allowlisted address → `RecipientNotAllowed()`
- any agent payment after owner `revoke()` → `MandateInactive()`

## Independently verified by the public indexer

`/v1/health` → `{ok:true, chain_id:2026042404, database:connected}`
`/v1/chain/status` → `total_indexed_contracts: 1` (the vault), txs indexed.
`/v1/txs/0x7e20…` → fully indexed: agent→vault, `status:1`, `AgentPayment` log.
`/v1/contracts/0x71c9…` → `creator: 0x7099…79C8`, creation tx recorded.

## Reproduce

```bash
# from a host that can reach the testnet RPC (directly or via SSH tunnel)
RPC_URL=<testnet-rpc> OWNER_KEY=<funded-key> \
  contracts/agent-finance/demo/agent_commerce_demo.sh
```

The same script runs against any node by repointing `RPC_URL`.

## Now reproducible over the public internet

The testnet is publicly reachable (wildcard TLS, all subdomains resolving), so
the demo runs with no tunnel:

```bash
RPC_URL=https://testnet.creditchain.org \
  contracts/agent-finance/demo/agent_commerce_demo.sh
```

A public run deployed vault `0x05Aa229Aec102f78CE0E852A812a388F076Aa555`
(creation tx `0x1a0bd38554cee973385be9d9ff795ba7b56d4ff286e174c7562a32ffe149297c`),
indexed and verifiable on the public explorer API. Public endpoints:

- RPC: `https://testnet.creditchain.org` (chainId 2026042404)
- Faucet: `POST https://faucet.creditchain.org/testnet/drip {"address":"0x.."}`
- Explorer API: `https://api-testnet.creditchain.org/v1/contracts/<vault>`
- Explorer UI: `https://scan.creditchain.org/?net=testnet`
