import {
  maxUint256,
  type Account,
  type Address,
  type Hex,
  type PublicClient,
  type WalletClient,
  zeroAddress,
} from "viem";
import { agentMandateVaultAbi } from "./abi.ts";
import { standards } from "./addresses.ts";

/** A mandate as the vault reports it. Amounts are in the asset's smallest unit. */
export interface Mandate {
  owner: Address;
  agent: Address;
  /** `0x000…0` for the chain's native coin. */
  asset: Address;
  budget: bigint;
  spent: bigint;
  balance: bigint;
  perTxMax: bigint;
  windowLimit: bigint;
  windowSeconds: bigint;
  windowStart: bigint;
  windowSpent: bigint;
  maxRelayFee: bigint;
  spentToOwner: bigint;
  expiry: bigint;
  allowlistEnabled: boolean;
  paused: boolean;
  revoked: boolean;
}

/** Terms for a new mandate. Zero in a limit means "no limit" there, as in the contract. */
export interface MandateTerms {
  agent: Address;
  /** Omit or zero address for the native coin. */
  asset?: Address;
  /** Initial funding. */
  amount: bigint;
  budget?: bigint;
  perTxMax?: bigint;
  windowLimit?: bigint;
  windowSeconds?: number;
  /** Unix seconds; 0 = never. */
  expiry?: number;
  allowlistEnabled?: boolean;
  maxRelayFee?: bigint;
}

/** What an agent signs so that anyone can submit its payment. */
export interface SpendAuthorization {
  mandateId: bigint;
  recipient: Address;
  amount: bigint;
  receipt: Hex;
  fee: bigint;
  nonce: bigint;
  deadline: bigint;
}

const SPEND_TYPES = {
  SpendAuthorization: [
    { name: "mandateId", type: "uint256" },
    { name: "recipient", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "receipt", type: "bytes32" },
    { name: "fee", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

const ERC20_APPROVE_ABI = [
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
] as const;

/**
 * ERC-AGM v2 at one vault address. Defaults to the reference vault, which has the same address on
 * every chain it is deployed to.
 */
export class Mandates {
  readonly publicClient: PublicClient;
  readonly vault: Address;

  constructor(publicClient: PublicClient, vault: Address = standards.agentMandateVault) {
    this.publicClient = publicClient;
    this.vault = vault;
  }

  /** Read one mandate. */
  async get(mandateId: bigint): Promise<Mandate> {
    return (await this.publicClient.readContract({
      address: this.vault,
      abi: agentMandateVaultAbi,
      functionName: "mandate",
      args: [mandateId],
    })) as Mandate;
  }

  /** The largest single payment the agent could make right now, every rail combined. */
  spendableNow(mandateId: bigint): Promise<bigint> {
    return this.publicClient.readContract({
      address: this.vault,
      abi: agentMandateVaultAbi,
      functionName: "spendableNow",
      args: [mandateId],
    });
  }

  nonceUsed(mandateId: bigint, nonce: bigint): Promise<boolean> {
    return this.publicClient.readContract({
      address: this.vault,
      abi: agentMandateVaultAbi,
      functionName: "nonceUsed",
      args: [mandateId, nonce],
    });
  }

  /**
   * Owner: create and fund a mandate. For an ERC-20, approves the vault for exactly `amount`
   * first. Returns the new mandate id.
   */
  async create(owner: WalletClient & { account: Account }, terms: MandateTerms): Promise<bigint> {
    const asset = terms.asset ?? zeroAddress;
    const native = asset === zeroAddress;
    if (!native && terms.amount > 0n) {
      const approval = await owner.writeContract({
        address: asset,
        abi: ERC20_APPROVE_ABI,
        functionName: "approve",
        args: [this.vault, terms.amount],
        chain: owner.chain,
        account: owner.account,
      });
      await this.publicClient.waitForTransactionReceipt({ hash: approval });
    }
    const args = {
      agent: terms.agent,
      asset,
      amount: terms.amount,
      budget: terms.budget ?? 0n,
      perTxMax: terms.perTxMax ?? 0n,
      windowLimit: terms.windowLimit ?? 0n,
      windowSeconds: BigInt(terms.windowSeconds ?? 0),
      expiry: BigInt(terms.expiry ?? 0),
      allowlistEnabled: terms.allowlistEnabled ?? false,
      maxRelayFee: terms.maxRelayFee ?? 0n,
    };
    const { request, result } = await this.publicClient.simulateContract({
      address: this.vault,
      abi: agentMandateVaultAbi,
      functionName: "createMandate",
      args: [args],
      value: native ? terms.amount : 0n,
      account: owner.account,
    });
    const hash = await owner.writeContract(request);
    const receipt = await this.publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new Error(`createMandate reverted in ${hash}`);
    return result;
  }

  /** Agent: pay directly (the agent's own account pays gas). */
  async spend(
    agent: WalletClient & { account: Account },
    mandateId: bigint,
    recipient: Address,
    amount: bigint,
    receipt: Hex,
  ): Promise<Hex> {
    const { request } = await this.publicClient.simulateContract({
      address: this.vault,
      abi: agentMandateVaultAbi,
      functionName: "spend",
      args: [mandateId, recipient, amount, receipt],
      account: agent.account,
    });
    return agent.writeContract(request);
  }

  /**
   * Agent: sign a payment for someone else to submit. The agent's key needs no gas and holds
   * nothing; the relayer takes `fee`, which the owner capped and which counts against the budget.
   */
  async sign(
    agent: WalletClient & { account: Account },
    auth: SpendAuthorization,
  ): Promise<Hex> {
    const chainId = await this.publicClient.getChainId();
    return agent.signTypedData({
      account: agent.account,
      domain: {
        name: "ERC-AGM AgentMandateVault",
        version: "2",
        chainId,
        verifyingContract: this.vault,
      },
      types: SPEND_TYPES,
      primaryType: "SpendAuthorization",
      message: auth,
    });
  }

  /** Anyone: submit a signed payment and collect its fee. */
  async relay(
    relayer: WalletClient & { account: Account },
    auth: SpendAuthorization,
    signature: Hex,
  ): Promise<Hex> {
    const { request } = await this.publicClient.simulateContract({
      address: this.vault,
      abi: agentMandateVaultAbi,
      functionName: "spendWithSignature",
      args: [auth, signature],
      account: relayer.account,
    });
    return relayer.writeContract(request);
  }

  /** Owner: the kill switch. Refunds the unspent balance; the agent can never spend again. */
  async revoke(owner: WalletClient & { account: Account }, mandateId: bigint): Promise<Hex> {
    const { request } = await this.publicClient.simulateContract({
      address: this.vault,
      abi: agentMandateVaultAbi,
      functionName: "revoke",
      args: [mandateId],
      account: owner.account,
    });
    return owner.writeContract(request);
  }

  /** A fresh random nonce. Nonces are unordered: any unused value works, once. */
  static randomNonce(): bigint {
    const bytes = crypto.getRandomValues(new Uint8Array(32));
    return BigInt(`0x${Buffer.from(bytes).toString("hex")}`) % maxUint256;
  }

  /**
   * The owner's worst case, in one sentence, before anything is signed: what the agent could take
   * in total and how fast. Fees are included, as the contract counts them.
   */
  static worstCase(m: Pick<Mandate, "budget" | "balance" | "perTxMax" | "windowLimit" | "windowSeconds" | "expiry">): string {
    const total = m.budget === 0n ? m.balance : m.budget < m.balance ? m.budget : m.balance;
    const parts = [`at most ${total} units in total`];
    if (m.perTxMax !== 0n) parts.push(`no more than ${m.perTxMax} per payment`);
    if (m.windowLimit !== 0n) parts.push(`no faster than ${m.windowLimit} per ${m.windowSeconds} s`);
    parts.push(m.expiry === 0n ? "with no expiry" : `stopping at ${new Date(Number(m.expiry) * 1000).toISOString()}`);
    return parts.join(", ");
  }
}
