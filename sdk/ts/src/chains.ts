import { defineChain } from "viem";

/** CreditChain's public testnet (Argos, proof of stake). Test CCC has no monetary value. */
export const creditchainArgos = defineChain({
  id: 2026042404,
  name: "CreditChain Argos Testnet",
  nativeCurrency: { name: "CreditChain Coin", symbol: "CCC", decimals: 18 },
  rpcUrls: { default: { http: ["https://testnet.creditchain.org"] } },
  blockExplorers: { default: { name: "CreditChain Scan", url: "https://scan.creditchain.org" } },
  testnet: true,
});

/**
 * CreditChain mainnet. Not live: it launches after an external audit and the key ceremony. The
 * definition exists so code can name it; there is no public RPC yet.
 */
export const creditchainMainnet = defineChain({
  id: 2026042405,
  name: "CreditChain",
  nativeCurrency: { name: "CreditChain Coin", symbol: "CCC", decimals: 18 },
  rpcUrls: { default: { http: [] } },
});
