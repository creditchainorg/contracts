# Canonical contracts on CreditChain

Agents, wallets and SDKs already know where certain contracts live, because their authors put them
at the same address on every chain. If CreditChain has the same code at the same address, all of
that software works here with no change. This directory puts them there and proves they are the
same.

| Contract | Address | Why |
|---|---|---|
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | Signature-based token approvals |
| x402 Exact Permit2 Proxy | `0x402085c248EeA27D92E8b30b2C58ed07f9E20001` | x402 `exact` payments in any ERC-20 |
| x402 Upto Permit2 Proxy | `0x4020A4f3b7b90ccA423B9fabCc0CE57C6C240002` | x402 `upto` payments |
| x402 Batch Settlement | `0x4020074e9dF2ce1deE5A9C1b5c3f541D02a10003` | Deposit once, pay per request with vouchers |
| ERC-3009 Deposit Collector | `0x4020806089470a89826cB9fB1f4059150b550004` | Gasless channel deposits (USDC-style tokens) |
| Permit2 Deposit Collector | `0x4020425FAf3B746C082C2f942b4E5159887B0005` | Gasless channel deposits (any ERC-20) |
| ERC-4337 EntryPoint v0.7 | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` | Smart accounts, paymasters |

All of them were created by the deterministic-deployment proxy, which CreditChain's genesis
preinstalls. None has an owner or an upgrade key.

## How authenticity is proven

A contract created by the proxy has the address `keccak256(0xff ++ proxy ++ salt ++ keccak256(initCode))[12:]`.
So init code that reproduces the canonical address *is* the deployed init code — no explorer, no
mirror and no person has to be trusted. `fetch-initcode.py` refuses anything else.

Sources of the init code in `initcode/` (all checked that way on 2026-10-20):

- Permit2 and EntryPoint v0.7: creation bytecode from Ethereum's Blockscout.
- The five x402 contracts: compiled from `coinbase/x402` (commit `0e6e8c5`, `contracts/evm`, its own
  pinned settings and submodules); the exact proxy uses the init code pinned in that repo.

## Deploying

```bash
canonical/fetch-initcode.py --check                     # verify the stored init code, offline
canonical/deploy.sh <rpc> --account <keystore-name>     # deploy whatever is missing
```

## What was checked on 2026-10-20

- Deployed all seven on a local chain with CreditChain mainnet's chain id (2026042405) and on one
  with Base's (8453).
- On the Base replica every contract's runtime code is **byte-identical** to the live contract on
  Base or Ethereum.
- On the CreditChain replica the x402 contracts and the EntryPoint are byte-identical too; Permit2
  differs only in the bytes where it stores its chain id and EIP-712 domain at construction, as it
  must.

## Not here: ERC-8004 registries

The canonical ERC-8004 registries (`0x8004A169…`, `0x8004BAa1…`) are upgradeable proxies. Their
proxies and implementations can be created by anyone through the Safe singleton factory (which
CreditChain's genesis also preinstalls), but activating them needs an upgrade transaction signed
for each chain by the ERC-8004 maintainers' owner key. CreditChain therefore has to ask them, as
the 20+ chains already listed did. Until then `PaidReviews` has nothing to post to on CreditChain.

Argos (the public testnet) has the deterministic-deployment proxy but not the Safe singleton
factory, so ERC-8004 can only be reproduced on mainnet or a local replica.
