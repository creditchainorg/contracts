import type { Address } from "viem";

/**
 * Contracts created by the deterministic-deployment proxy with a fixed salt: the same address on
 * every EVM chain that has them. `deployments.json` in the contracts repo says which chains do.
 */
export const standards = {
  /** ERC-AGM v2 reference implementation. */
  agentMandateVault: "0x56bf4e5214d8978957B7EA0BeCe4FB7ae0f1e577",
  /** Post-quantum escape keys. */
  quantumEscapeRegistry: "0x8cd71d9D53FF0501145eEd2e8F740B49Cb25f108",
} as const satisfies Record<string, Address>;

/** PaidReviews differs between mainnets and testnets because ERC-8004 publishes two registry pairs. */
export const paidReviews = {
  mainnet: "0x399314ffa023D4aD441366bB9e1cE0b0548B50aD",
} as const satisfies Record<string, Address>;

/** Third-party contracts at one address across chains (x402, Permit2, ERC-4337, ERC-8004). */
export const canonical = {
  permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  x402ExactPermit2Proxy: "0x402085c248EeA27D92E8b30b2C58ed07f9E20001",
  x402UptoPermit2Proxy: "0x4020A4f3b7b90ccA423B9fabCc0CE57C6C240002",
  x402BatchSettlement: "0x4020074e9dF2ce1deE5A9C1b5c3f541D02a10003",
  erc3009DepositCollector: "0x4020806089470a89826cB9fB1f4059150b550004",
  permit2DepositCollector: "0x4020425FAf3B746C082C2f942b4E5159887B0005",
  entryPointV07: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
  erc8004IdentityMainnet: "0x8004A169FB4a3325136EB29fA0ceB6D2e539a432",
  erc8004ReputationMainnet: "0x8004BAa17C55a88189AE136b182e5fdA19dE9b63",
  erc8004IdentityTestnet: "0x8004A818BFB912233c491871b3d84c89A494BD9e",
  erc8004ReputationTestnet: "0x8004B663056A597Dffe9eCcC1965A193B7388713",
} as const satisfies Record<string, Address>;

/** EIP-8355 ML-DSA verification precompiles (CreditChain, from its ML-DSA network upgrade). */
export const mlDsaPrecompiles = {
  44: "0x0000000000000000000000000000000000000012",
  65: "0x0000000000000000000000000000000000000013",
  87: "0x0000000000000000000000000000000000000014",
} as const satisfies Record<number, Address>;
