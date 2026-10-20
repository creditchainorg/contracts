import { keccak256, zeroHash, type Account, type Address, type Hex, type PublicClient, type WalletClient } from "viem";
import { quantumEscapeRegistryAbi } from "./abi.ts";
import { standards, mlDsaPrecompiles } from "./addresses.ts";

/** Key schemes the registry understands. */
export const Scheme = {
  wotsPlusKeccak: 1,
  mlDsa44: 2,
  mlDsa65: 3,
  mlDsa87: 4,
} as const;
export type Scheme = (typeof Scheme)[keyof typeof Scheme];

export interface Escape {
  scheme: number;
  commitment: Hex;
  pubSeed: Hex;
  recovery: Address;
  registeredAt: bigint;
  rotation: bigint;
}

/** The commitment registered for an ML-DSA key: keccak256 of its FIPS 204 public key encoding. */
export function mlDsaCommitment(publicKey: Hex): Hex {
  return keccak256(publicKey);
}

/** Read and build calls for the QuantumEscapeRegistry (same address on every chain). */
export class QuantumEscape {
  readonly publicClient: PublicClient;
  readonly registry: Address;

  constructor(publicClient: PublicClient, registry: Address = standards.quantumEscapeRegistry) {
    this.publicClient = publicClient;
    this.registry = registry;
  }

  async of(account: Address): Promise<Escape> {
    return (await this.publicClient.readContract({
      address: this.registry,
      abi: quantumEscapeRegistryAbi,
      functionName: "escapeOf",
      args: [account],
    })) as Escape;
  }

  /**
   * Register the caller's escape key. Possible once; after that only the post-quantum key itself
   * rotates it. For ML-DSA pass the {@link mlDsaCommitment} and no seed.
   */
  async register(
    wallet: WalletClient & { account: Account },
    args: { scheme: Scheme; commitment: Hex; pubSeed?: Hex; recovery: Address },
  ): Promise<Hex> {
    const { request } = await this.publicClient.simulateContract({
      address: this.registry,
      abi: quantumEscapeRegistryAbi,
      functionName: "register",
      args: [args.scheme, args.commitment, args.pubSeed ?? zeroHash, args.recovery],
      account: wallet.account,
    });
    return wallet.writeContract(request);
  }

  /** Has `account` registered an escape key? */
  async isRegistered(account: Address): Promise<boolean> {
    return (await this.of(account)).scheme !== 0;
  }

  /** What the current post-quantum key must sign to rotate to the given new key. */
  rotationDigest(args: {
    account: Address;
    rotation: bigint;
    scheme: Scheme;
    commitment: Hex;
    pubSeed: Hex;
    recovery: Address;
  }): Promise<Hex> {
    return this.publicClient.readContract({
      address: this.registry,
      abi: quantumEscapeRegistryAbi,
      functionName: "rotationDigest",
      args: [args.account, args.rotation, args.scheme, args.commitment, args.pubSeed, args.recovery],
    });
  }

  /**
   * Does this chain have the EIP-8355 ML-DSA precompiles? A precompile answers with exactly 32
   * bytes even for garbage input; an address without one answers with nothing.
   */
  async hasMlDsa(level: 44 | 65 | 87 = 65): Promise<boolean> {
    const { data } = await this.publicClient.call({ to: mlDsaPrecompiles[level], data: "0x00" });
    return data !== undefined && data.length === 66;
  }
}
