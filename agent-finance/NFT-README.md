# CreditChain NFT reference stack

This Foundry project contains a public-testnet NFT vertical slice:

- `src/CreditNFTCollection.sol` — ERC-721 metadata, ERC-2981 royalties,
  provenance commitment, maximum supply, creator minters, and permanent freeze.
- `src/CreditNFTMarket.sol` — native-CCC non-custodial fixed-price listings,
  pull payouts, stale-listing protection, fee cap, pause, and `buyFor`.
- `src/CreditNFTFactory.sol` — permissionless, fee-free collection creation
  with no factory administrator or authority over creator-owned collections.
- `script/DeployCreditNFTCollection.s.sol` — creator-facing collection deploy.
- `script/DeployCreditNFTMarket.s.sol` — operator-facing shared market deploy.
- `script/DeployCreditNFTFactory.s.sol` — operator-facing creator factory deploy.
- `script/DeployCreditNFT.s.sol` — combined local/reference-stack deploy. A
  production network does not run this once per creator.
- Every deployment script refuses CreditChain mainnet (chain ID `2026042405`).
- `test/CreditNFTMarket.t.sol` — 18 factory, collection, market, adversarial,
  and settlement behavior tests.

## Test

```bash
export PATH="$HOME/.foundry/bin:$PATH"
forge test --match-path test/CreditNFTMarket.t.sol -vv
```

## Deploy a collection to testnet

Use an encrypted Foundry account. Do not put a recovery phrase or raw private
key in a shell script.

```bash
cast wallet import creator --interactive

export NFT_NAME="Origin"
export NFT_SYMBOL="ORIGIN"
export NFT_OWNER="0x..."
export NFT_MAX_SUPPLY=100
export NFT_CONTRACT_URI="ipfs://.../collection.json"
export NFT_PROVENANCE_HASH="0x..."
export NFT_ROYALTY_RECEIVER="0x..."
export NFT_ROYALTY_BPS=500

forge script script/DeployCreditNFTCollection.s.sol:DeployCreditNFTCollection \
  --rpc-url testnet \
  --account creator \
  --broadcast
```

Verify the deployed bytecode and source in CreditChain Scan before minting. Use
the single published CreditChain Market address for approvals and listings.

The protocol operator deploys that shared market once with
`DeployCreditNFTMarket.s.sol`, verifies it, and sets its address in
`CC_NFT_MARKET_ADDRESSES` before replaying/restarting the indexer. The allowlist
is mandatory: any contract can copy an event signature, so events alone cannot
establish an official market identity.

## Testnet release sequence

1. Run the full Foundry suite and archive the audited source commit.
2. Deploy `CreditNFTFactory` and `CreditNFTMarket` from fresh testnet operator
   accounts. Do not deploy the combined demo script to a public network.
3. Verify both contracts in Scan and publish owner, fee recipient, fee basis
   points, and deployment transaction hashes.
4. Apply `creditchain-browser/docs/migrations/20260809-nft-index.sql` to a
   snapshot first, then testnet.
5. Configure API and indexer with the same allowlists:

   ```dotenv
   CC_NFT_FACTORY_ADDRESSES=0xOfficialFactory
   CC_NFT_MARKET_ADDRESSES=0xOfficialMarket
   CC_NFT_TRADING_ENABLED=false
   ```

6. Replay from the factory deployment block and verify collection launches,
   ownership, safe metadata, listings, and sales in the Browser API.
7. Rehearse launch → mint → approve → list → buyFor → withdraw → cancel →
   invalidate → burn using test wallets.
8. Only after the signed release checklist passes, change testnet
   `CC_NFT_TRADING_ENABLED=true` and redeploy the API. Mainnet compose keeps the
   value hardcoded to `false`.

Factory provenance and source verification are separate trust signals. The
official catalog accepts a collection created by an allowlisted factory or one
whose bytecode is source-verified. Neither signal is a creator endorsement.

## Security posture

This is testnet reference software. It has not received an independent audit.
The deploy script intentionally blocks CreditChain mainnet. Mainnet deployment
requires contract audit, chain PoS/readiness gates, administrator custody review,
multisig controls, monitoring, and incident rehearsal.
