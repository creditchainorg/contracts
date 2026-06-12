# Hello CreditChain

Minimal Foundry starter for deploying a Solidity contract to CreditChain
Devnet or Testnet.

CreditChain is EVM-compatible, so this project intentionally uses standard
Solidity and Foundry conventions. There are no CreditChain-specific imports or
framework hooks.

## Networks

| Network | RPC alias | Chain ID | Purpose |
|---|---|---:|---|
| Devnet | `creditchain_devnet` | `2026042403` | fast iteration, resettable |
| Testnet | `creditchain_testnet` | `2026042404` | stable integration testing |

## Use

```bash
forge install foundry-rs/forge-std --no-git
forge test

# Fund the deployer from https://faucet.creditchain.org/testnet first.
forge script script/Deploy.s.sol:Deploy \
  --rpc-url creditchain_testnet \
  --private-key $PRIVATE_KEY \
  --broadcast
```

After deployment, record:

- network id and chain id,
- contract address,
- deploy transaction hash,
- deployer address,
- git commit SHA,
- compiler version and constructor arguments.

Test-network CCC has no monetary value. Never commit private keys.
