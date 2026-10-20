// A real MCP client talks to the server over an in-memory transport, against a local chain with the
// standards deployed (see ../ts/test/chain.test.ts). Skipped when that chain is not running.
import { test } from "node:test";
import assert from "node:assert/strict";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createPublicClient, createWalletClient, http, parseEther, type PublicClient } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { Mandates, standards } from "@creditchain/agents";
import { createServer } from "../src/server.ts";

const RPC = process.env.SDK_TEST_RPC ?? "http://127.0.0.1:18547";
// Public anvil development keys: local test chains only.
const OWNER = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as const;
const AGENT = "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba" as const;
const RELAYER = "0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e" as const;
const SHOP = "0x000000000000000000000000000000000000c0fe";

const publicClient = createPublicClient({ transport: http(RPC) }) as PublicClient;
let up = false;
try {
  up = (await publicClient.getBytecode({ address: standards.agentMandateVault })) !== undefined;
} catch {}

async function connect(env: { agent?: `0x${string}`; relayer?: `0x${string}`; payLimit?: bigint }) {
  const server = createServer({ rpc: RPC, agentKey: env.agent, relayerKey: env.relayer, relayFee: env.relayer ? 1000n : 0n, vault: standards.agentMandateVault, payLimit: env.payLimit, allowMainnet: false });
  const [a, b] = InMemoryTransport.createLinkedPair();
  const client = new Client({ name: "test", version: "1" });
  await Promise.all([server.connect(a), client.connect(b)]);
  return client;
}
const text = (r: any) => r.content[0].text as string;

test("lists its tools", { skip: !up && "no local chain" }, async () => {
  const client = await connect({});
  const names = (await client.listTools()).tools.map((t) => t.name).sort();
  assert.deepEqual(names, ["contracts", "escape_status", "mandate_pay", "mandate_sign", "mandate_status", "receipt_hash"]);
});

test("an agent pays within its mandate through a relayer, and is refused outside it", { skip: !up && "no local chain" }, async () => {
  const owner = createWalletClient({ transport: http(RPC), account: privateKeyToAccount(OWNER), chain: { id: await publicClient.getChainId() } as any });
  const agentAddress = privateKeyToAccount(AGENT).address;
  const mandates = new Mandates(publicClient);
  const id = await mandates.create(owner as any, { agent: agentAddress, amount: parseEther("1"), perTxMax: parseEther("0.1"), maxRelayFee: 1000n });

  const reader = await connect({});
  const status = JSON.parse(text(await reader.callTool({ name: "mandate_status", arguments: { mandateId: id.toString() } })));
  assert.equal(status.agent, agentAddress);
  assert.equal(status.thisServerIsTheAgent, false);

  const noKey = await reader.callTool({ name: "mandate_pay", arguments: { mandateId: id.toString(), recipient: SHOP, amount: "1" } });
  assert.equal(noKey.isError, true);
  assert.match(text(noKey), /No AGENT_PRIVATE_KEY/);

  const client = await connect({ agent: AGENT, relayer: RELAYER, payLimit: parseEther("0.5") });
  const before = await publicClient.getBalance({ address: SHOP });
  const paid = await client.callTool({ name: "mandate_pay", arguments: { mandateId: id.toString(), recipient: SHOP, amount: parseEther("0.05").toString(), purpose: "inference: 812 tokens", url: "https://api.example/v1/infer" } });
  assert.equal(paid.isError, undefined, text(paid));
  const result = JSON.parse(text(paid));
  assert.equal(result.status, "success");
  assert.equal(result.relayed, true);
  assert.equal(result.receipt.purpose, "inference: 812 tokens");
  assert.equal((await publicClient.getBalance({ address: SHOP })) - before, parseEther("0.05"));
  assert.equal((await publicClient.getBalance({ address: agentAddress })) > 0n, true); // anvil-funded, untouched by relaying

  const tooMuch = await client.callTool({ name: "mandate_pay", arguments: { mandateId: id.toString(), recipient: SHOP, amount: parseEther("0.2").toString() } });
  assert.equal(tooMuch.isError, true);
  assert.match(text(tooMuch), /can pay at most/);

  const overLocal = await client.callTool({ name: "mandate_pay", arguments: { mandateId: id.toString(), recipient: SHOP, amount: parseEther("0.6").toString() } });
  assert.match(text(overLocal), /PAY_LIMIT/);

  const signed = JSON.parse(text(await client.callTool({ name: "mandate_sign", arguments: { mandateId: id.toString(), recipient: SHOP, amount: "7" } })));
  assert.match(signed.signature, /^0x[0-9a-f]{130}$/);
  assert.equal(signed.authorization.amount, "7");
});

test("receipt_hash is order-independent", { skip: !up && "no local chain" }, async () => {
  const client = await connect({});
  const a = JSON.parse(text(await client.callTool({ name: "receipt_hash", arguments: { document: { b: 1, a: 2 } } })));
  const b = JSON.parse(text(await client.callTool({ name: "receipt_hash", arguments: { document: { a: 2, b: 1 } } })));
  assert.equal(a.hash, b.hash);
  assert.equal(a.canonical, '{"a":2,"b":1}');
});
