// Against a local chain with the standards deployed at their canonical addresses:
//   anvil --chain-id 2026042404 --port 18547 &
//   (cd ../../standards && WITH_REVIEWS=false DEPLOYER_KEY=<anvil key> forge script script/DeployStandards.s.sol --rpc-url http://127.0.0.1:18547 --broadcast)
// Skipped when that chain is not running.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createPublicClient, createWalletClient, http, parseEther, type PublicClient } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { creditchainArgos } from "../src/chains.ts";
import { Mandates, QuantumEscape, Scheme, makeReceipt, standards } from "../src/index.ts";

const RPC = process.env.SDK_TEST_RPC ?? "http://127.0.0.1:18547";
const chain = { ...creditchainArgos, rpcUrls: { default: { http: [RPC] } } };
const publicClient = createPublicClient({ chain, transport: http(RPC) }) as PublicClient;
// Public anvil/hardhat development keys: local test chains only.
const wallet = (k: `0x${string}`) => createWalletClient({ chain, transport: http(RPC), account: privateKeyToAccount(k) });
const owner = wallet("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
const agent = wallet("0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a");
const relayer = wallet("0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6");
const shop = "0x000000000000000000000000000000000000beef" as const;

async function chainUp(): Promise<boolean> {
  try {
    return (await publicClient.getBytecode({ address: standards.agentMandateVault })) !== undefined;
  } catch {
    return false;
  }
}
const up = await chainUp();

test("a gasless agent pays through a relayer, inside the owner's limits", { skip: !up && "no local chain" }, async () => {
  const mandates = new Mandates(publicClient);
  const id = await mandates.create(owner, {
    agent: agent.account.address,
    amount: parseEther("1"),
    budget: parseEther("0.5"),
    perTxMax: parseEther("0.1"),
    maxRelayFee: parseEther("0.001"),
  });
  const before = await mandates.get(id);
  assert.equal(before.agent, agent.account.address);
  assert.equal(await mandates.spendableNow(id), parseEther("0.1"));
  assert.match(Mandates.worstCase(before), /at most 500000000000000000 units in total, no more than 100000000000000000 per payment/);

  const { hash } = makeReceipt({ mandate: `eip155:${chain.id}:${mandates.vault}/${id}`, request: { method: "POST", url: "https://api.example/v1/infer" } });
  const auth = {
    mandateId: id,
    recipient: shop,
    amount: parseEther("0.05"),
    receipt: hash,
    fee: parseEther("0.0005"),
    nonce: Mandates.randomNonce(),
    deadline: BigInt(Math.floor(Date.now() / 1000) + 600),
  };
  const signature = await mandates.sign(agent, auth);
  const shopBefore = await publicClient.getBalance({ address: shop });
  const tx = await mandates.relay(relayer, auth, signature);
  assert.equal((await publicClient.waitForTransactionReceipt({ hash: tx })).status, "success");

  assert.equal((await publicClient.getBalance({ address: shop })) - shopBefore, parseEther("0.05"));
  const after = await mandates.get(id);
  assert.equal(after.spent, parseEther("0.0505"), "the relay fee counts against the budget");
  assert.equal(await mandates.nonceUsed(id, auth.nonce), true);

  // Replaying the same signature fails; so does one above the per-payment cap.
  await assert.rejects(mandates.relay(relayer, auth, signature));
  const tooBig = { ...auth, amount: parseEther("0.2"), nonce: Mandates.randomNonce() };
  await assert.rejects(mandates.relay(relayer, tooBig, await mandates.sign(agent, tooBig)));

  const revoke = await mandates.revoke(owner, id);
  await publicClient.waitForTransactionReceipt({ hash: revoke });
  assert.equal((await mandates.get(id)).revoked, true);
  assert.equal(await mandates.spendableNow(id), 0n);
});

test("escape keys: register once, detect the ML-DSA precompile", { skip: !up && "no local chain" }, async () => {
  const escape = new QuantumEscape(publicClient);
  const fresh = wallet("0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a");
  if (!(await escape.isRegistered(fresh.account.address))) {
    const tx = await escape.register(fresh, { scheme: Scheme.mlDsa65, commitment: `0x${"ab".repeat(32)}`, recovery: shop });
    await publicClient.waitForTransactionReceipt({ hash: tx });
  }
  const e = await escape.of(fresh.account.address);
  assert.equal(e.scheme, Scheme.mlDsa65);
  assert.equal(e.recovery.toLowerCase(), shop);
  await assert.rejects(escape.register(fresh, { scheme: Scheme.mlDsa65, commitment: `0x${"cd".repeat(32)}`, recovery: shop }), "registering twice");
  assert.equal(await escape.hasMlDsa(65), false, "anvil has no EIP-8355 precompiles");
});
