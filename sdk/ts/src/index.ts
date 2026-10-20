/**
 * @creditchain/agents — bounded, revocable spending for AI agents on any EVM chain.
 *
 * - {@link Mandates}: ERC-AGM v2. An owner funds a mandate in the native coin or any ERC-20 and
 *   names an agent; the chain enforces budget, per-payment cap, rate, allowlist, expiry and relay
 *   fee on every payment. The agent can sign payments for others to submit, so its key holds
 *   nothing and needs no gas.
 * - {@link makeReceipt}: the commitment each payment carries to what it paid for.
 * - {@link QuantumEscape}: post-quantum escape keys, registered while ECDSA is still trustworthy.
 * - Addresses of the canonical x402, Permit2, ERC-4337 and ERC-8004 contracts.
 *
 * Not audited. Use test assets until it is.
 */
export { agentMandateVaultAbi, quantumEscapeRegistryAbi, paidReviewsAbi } from "./abi.ts";
export { standards, paidReviews, canonical, mlDsaPrecompiles } from "./addresses.ts";
export { creditchainArgos, creditchainMainnet } from "./chains.ts";
export { Mandates, type Mandate, type MandateTerms, type SpendAuthorization } from "./mandates.ts";
export { canonicalJson, makeReceipt, receiptHash, type Receipt } from "./receipts.ts";
export { QuantumEscape, Scheme, mlDsaCommitment, type Escape } from "./escape.ts";
