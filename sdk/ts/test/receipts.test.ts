import { test } from "node:test";
import assert from "node:assert/strict";
import { keccak256, stringToBytes } from "viem";
import { canonicalJson, makeReceipt, receiptHash } from "../src/receipts.ts";

test("canonical JSON sorts keys at every level and drops undefined", () => {
  assert.equal(
    canonicalJson({ b: 1, a: { d: [3, { z: 1, y: 2 }], c: "x" }, e: undefined }),
    '{"a":{"c":"x","d":[3,{"y":2,"z":1}]},"b":1}',
  );
});

test("canonical JSON matches RFC 8785 for strings and numbers", () => {
  assert.equal(canonicalJson({ s: "é\n\"", n: 1e21, m: 0.1, z: -0 }), '{"m":0.1,"n":1e+21,"s":"é\\n\\"","z":0}');
  assert.throws(() => canonicalJson({ x: Number.NaN }));
  assert.throws(() => canonicalJson({ x: 1n }));
});

test("the same receipt hashes the same whatever the key order", () => {
  const a = { type: "erc-agm-receipt/1", mandate: "eip155:1:0xabc/7", createdAt: "2026-10-20T00:00:00Z", quote: { amount: "1200", asset: "0x0" } } as const;
  const b = { quote: { asset: "0x0", amount: "1200" }, createdAt: "2026-10-20T00:00:00Z", mandate: "eip155:1:0xabc/7", type: "erc-agm-receipt/1" } as const;
  assert.equal(receiptHash(a), receiptHash(b));
  assert.equal(receiptHash(a), keccak256(stringToBytes(canonicalJson(a))));
});

test("makeReceipt stamps the type and time and returns the hash", () => {
  const { receipt, hash } = makeReceipt({ mandate: "eip155:2026042404:0x56bf/1", createdAt: "2026-10-20T12:00:00Z", request: { method: "POST", url: "https://api.example/v1/infer" } });
  assert.equal(receipt.type, "erc-agm-receipt/1");
  assert.equal(hash, receiptHash(receipt));
  assert.match(hash, /^0x[0-9a-f]{64}$/);
});
