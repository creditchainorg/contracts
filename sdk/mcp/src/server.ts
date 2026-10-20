#!/usr/bin/env node
/**
 * creditchain-agents-mcp — lets an AI agent pay within an ERC-AGM mandate, and nothing more.
 *
 * The agent's key lives in this server's environment. It is a *mandate* key: the chain lets it
 * spend only what its owner granted, at the rate and to the recipients the owner allowed, until
 * the owner revokes it. With a relayer configured, the key holds no coins at all — it only signs.
 *
 * Environment:
 *   CREDITCHAIN_RPC        RPC URL (default: Argos testnet)
 *   AGENT_PRIVATE_KEY      the mandate's agent key (needed to pay or sign)
 *   RELAYER_PRIVATE_KEY    optional: submits the agent's signed payments and pays gas
 *   RELAY_FEE              fee per relayed payment, in the mandate asset's smallest unit (default 0)
 *   MANDATE_VAULT          vault address (default: the ERC-AGM v2 reference vault)
 *   PAY_LIMIT              optional extra local cap per payment, smallest unit
 *   CREDITCHAIN_ALLOW_MAINNET=1   required before it will touch CreditChain mainnet (pre-audit)
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import {
  createPublicClient,
  createWalletClient,
  http,
  isAddress,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
  Mandates,
  QuantumEscape,
  canonical,
  canonicalJson,
  makeReceipt,
  mlDsaPrecompiles,
  receiptHash,
  standards,
  type Receipt,
  type SpendAuthorization,
} from "@creditchain/agents";

export interface Config {
  rpc: string;
  agentKey?: Hex;
  relayerKey?: Hex;
  relayFee: bigint;
  vault: Address;
  payLimit?: bigint;
  allowMainnet: boolean;
}

const CREDITCHAIN_MAINNET = 2026042405;

export function configFromEnv(env: NodeJS.ProcessEnv = process.env): Config {
  return {
    rpc: env.CREDITCHAIN_RPC ?? "https://testnet.creditchain.org",
    agentKey: env.AGENT_PRIVATE_KEY as Hex | undefined,
    relayerKey: env.RELAYER_PRIVATE_KEY as Hex | undefined,
    relayFee: BigInt(env.RELAY_FEE ?? "0"),
    vault: (env.MANDATE_VAULT as Address | undefined) ?? standards.agentMandateVault,
    payLimit: env.PAY_LIMIT ? BigInt(env.PAY_LIMIT) : undefined,
    allowMainnet: env.CREDITCHAIN_ALLOW_MAINNET === "1",
  };
}

const json = (value: unknown) => ({
  content: [
    {
      type: "text" as const,
      text: JSON.stringify(value, (_k, v) => (typeof v === "bigint" ? v.toString() : v), 2),
    },
  ],
});

const refuse = (message: string) => ({ isError: true, content: [{ type: "text" as const, text: message }] });

const amount = z.string().regex(/^[0-9]+$/, "a whole number of the asset's smallest unit");
const address = z.string().refine((s) => isAddress(s), "an 0x address");

export function createServer(config: Config): McpServer {
  const publicClient = createPublicClient({ transport: http(config.rpc) }) as PublicClient;
  const mandates = new Mandates(publicClient, config.vault);
  const escape = new QuantumEscape(publicClient);
  const agent = config.agentKey ? privateKeyToAccount(config.agentKey) : undefined;
  const relayer = config.relayerKey ? privateKeyToAccount(config.relayerKey) : undefined;

  async function chainCheck(): Promise<string | undefined> {
    const id = await publicClient.getChainId();
    if (id === CREDITCHAIN_MAINNET && !config.allowMainnet) {
      return "Refusing CreditChain mainnet: these contracts are not audited yet. Set CREDITCHAIN_ALLOW_MAINNET=1 to override.";
    }
    return undefined;
  }

  async function authorize(input: {
    mandateId: string;
    recipient: string;
    amount: string;
    purpose?: string;
    url?: string;
  }): Promise<{ auth: SpendAuthorization; signature: Hex; receipt: Receipt } | string> {
    if (!agent) return "No AGENT_PRIVATE_KEY configured: this server can read mandates but not pay.";
    const blocked = await chainCheck();
    if (blocked) return blocked;
    const id = BigInt(input.mandateId);
    const value = BigInt(input.amount);
    if (config.payLimit !== undefined && value > config.payLimit) {
      return `Refused: ${value} is above this server's PAY_LIMIT of ${config.payLimit}.`;
    }
    const m = await mandates.get(id);
    if (m.agent.toLowerCase() !== agent.address.toLowerCase()) {
      return `Mandate ${id} belongs to agent ${m.agent}, not to this server's key ${agent.address}.`;
    }
    const fee = relayer ? config.relayFee : 0n;
    const spendable = await mandates.spendableNow(id);
    if (value + fee > spendable) {
      return `Refused before signing: mandate ${id} can pay at most ${spendable} right now (requested ${value} + fee ${fee}).`;
    }
    const chainId = await publicClient.getChainId();
    const { receipt, hash } = makeReceipt({
      mandate: `eip155:${chainId}:${config.vault}/${id}`,
      request: input.url ? { url: input.url } : undefined,
      purpose: input.purpose,
      quote: { amount: value.toString(), asset: m.asset },
    });
    const auth: SpendAuthorization = {
      mandateId: id,
      recipient: input.recipient as Address,
      amount: value,
      receipt: hash,
      fee,
      nonce: Mandates.randomNonce(),
      deadline: BigInt(Math.floor(Date.now() / 1000) + 600),
    };
    const agentWallet = createWalletClient({ transport: http(config.rpc), account: agent });
    const signature = await mandates.sign(agentWallet, auth);
    return { auth, signature, receipt };
  }

  const server = new McpServer({ name: "creditchain-agents", version: "0.1.0" });

  server.registerTool(
    "contracts",
    {
      title: "Contract addresses",
      description:
        "Addresses of the ERC-AGM v2 mandate vault, the quantum escape registry, and the canonical x402, Permit2, ERC-4337 and ERC-8004 contracts. Each has the same address on every EVM chain that has it.",
      inputSchema: {},
      annotations: { readOnlyHint: true },
    },
    async () => json({ rpc: config.rpc, chainId: await publicClient.getChainId(), vault: config.vault, standards, canonical, mlDsaPrecompiles }),
  );

  server.registerTool(
    "mandate_status",
    {
      title: "Mandate status",
      description:
        "Everything about one spending mandate: owner, agent, asset, limits, what has been spent, what can be spent right now, and the owner's worst case in one sentence.",
      inputSchema: { mandateId: amount },
      annotations: { readOnlyHint: true },
    },
    async ({ mandateId }) => {
      const id = BigInt(mandateId);
      const m = await mandates.get(id);
      if (m.owner === "0x0000000000000000000000000000000000000000") return refuse(`Mandate ${id} does not exist.`);
      return json({ mandateId: id, ...m, spendableNow: await mandates.spendableNow(id), worstCase: Mandates.worstCase(m), thisServerIsTheAgent: agent ? m.agent.toLowerCase() === agent.address.toLowerCase() : false });
    },
  );

  server.registerTool(
    "mandate_pay",
    {
      title: "Pay from a mandate",
      description:
        "Pay `amount` (smallest unit of the mandate's asset) to `recipient` from mandate `mandateId`, with a receipt recording what it was for. The chain enforces the owner's limits; a payment outside them is refused and moves nothing. With a relayer configured, the agent pays no gas.",
      inputSchema: {
        mandateId: amount,
        recipient: address,
        amount,
        purpose: z.string().max(200).optional().describe("what this payment buys, recorded in the receipt"),
        url: z.string().url().optional().describe("the paid-for request, recorded in the receipt"),
      },
      annotations: { destructiveHint: false, openWorldHint: true },
    },
    async (input) => {
      const result = await authorize(input);
      if (typeof result === "string") return refuse(result);
      const { auth, signature, receipt } = result;
      const sender = relayer ?? agent!;
      const wallet = createWalletClient({ transport: http(config.rpc), account: sender });
      const hash = relayer
        ? await mandates.relay(wallet, auth, signature)
        : await mandates.spend(wallet, auth.mandateId, auth.recipient, auth.amount, auth.receipt);
      const mined = await publicClient.waitForTransactionReceipt({ hash });
      return json({ transaction: hash, status: mined.status, relayed: Boolean(relayer), fee: auth.fee, receiptHash: auth.receipt, receipt, keepThisReceipt: "The chain stores only the hash; keep the document to prove what this payment bought." });
    },
  );

  server.registerTool(
    "mandate_sign",
    {
      title: "Sign a payment for someone else to submit",
      description:
        "Like mandate_pay, but returns the signed authorization instead of sending it, for an external relayer or facilitator. Valid for 10 minutes; usable once.",
      inputSchema: { mandateId: amount, recipient: address, amount, purpose: z.string().max(200).optional(), url: z.string().url().optional() },
      annotations: { readOnlyHint: true },
    },
    async (input) => {
      const result = await authorize(input);
      if (typeof result === "string") return refuse(result);
      return json({ vault: config.vault, authorization: result.auth, signature: result.signature, receipt: result.receipt });
    },
  );

  server.registerTool(
    "receipt_hash",
    {
      title: "Receipt hash",
      description: "The 32-byte commitment of a receipt document: keccak256 of its RFC 8785 canonical JSON.",
      inputSchema: { document: z.record(z.unknown()) },
      annotations: { readOnlyHint: true },
    },
    async ({ document }) => json({ canonical: canonicalJson(document), hash: receiptHash(document as Receipt) }),
  );

  server.registerTool(
    "escape_status",
    {
      title: "Post-quantum escape key",
      description:
        "Whether an account has registered a post-quantum escape key (and which scheme and recovery address), and whether this chain can verify ML-DSA signatures natively (EIP-8355).",
      inputSchema: { account: address },
      annotations: { readOnlyHint: true },
    },
    async ({ account }) => {
      const e = await escape.of(account as Address);
      return json({ account, registered: e.scheme !== 0, ...e, chainHasMlDsaPrecompiles: await escape.hasMlDsa(65) });
    },
  );

  return server;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const server = createServer(configFromEnv());
  await server.connect(new StdioServerTransport());
}
