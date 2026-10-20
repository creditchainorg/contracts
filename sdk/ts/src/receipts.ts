import { keccak256, stringToBytes, type Hex } from "viem";

/**
 * What a payment bought, as the RECOMMENDED `erc-agm-receipt/1` document from ERC-AGM v2. The
 * chain stores only its hash (the payment's `receipt`); the parties keep the document and can
 * later prove what each payment was for.
 */
export interface Receipt {
  type: "erc-agm-receipt/1";
  /** `eip155:<chainId>:<vault>/<mandateId>` */
  mandate: string;
  request?: { method?: string; url?: string; bodyHash?: Hex; tool?: string };
  service?: { agentRegistry?: string; agentId?: number; name?: string };
  quote?: { amount: string; asset: string };
  createdAt: string;
  [extra: string]: unknown;
}

/**
 * RFC 8785 JSON canonicalisation: sorted keys, no insignificant whitespace, ECMAScript number
 * and string forms. Two parties that hold the same document always compute the same hash.
 */
export function canonicalJson(value: unknown): string {
  if (value === null || typeof value === "boolean") return JSON.stringify(value);
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new Error("receipts cannot contain NaN or Infinity");
    return JSON.stringify(value);
  }
  if (typeof value === "string") return JSON.stringify(value);
  if (typeof value === "bigint") throw new Error("encode bigints as decimal strings in receipts");
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>)
      .filter(([, v]) => v !== undefined)
      .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
    return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${canonicalJson(v)}`).join(",")}}`;
  }
  throw new Error(`cannot canonicalise a ${typeof value}`);
}

/** The 32-byte commitment a payment carries: keccak256 of the canonical JSON. */
export function receiptHash(receipt: Receipt): Hex {
  return keccak256(stringToBytes(canonicalJson(receipt)));
}

/** Build a receipt for a mandate payment and return it with its hash. */
export function makeReceipt(
  fields: { mandate: string; createdAt?: string } & Partial<Omit<Receipt, "type" | "mandate" | "createdAt">>,
): { receipt: Receipt; hash: Hex } {
  const receipt = {
    ...fields,
    type: "erc-agm-receipt/1",
    createdAt: fields.createdAt ?? new Date().toISOString(),
  } as Receipt;
  return { receipt, hash: receiptHash(receipt) };
}
