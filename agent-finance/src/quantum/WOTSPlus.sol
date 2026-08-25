// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title WOTSPlus — Winternitz One-Time Signatures for the EVM
/// @notice A post-quantum signature verifier whose ONLY cryptographic assumption
///         is that keccak256 behaves like a hash function.
///
/// WHY THIS EXISTS
/// ---------------
/// Every EVM account today is protected by secp256k1 ECDSA. ECDSA rests on the
/// discrete-log problem, which Shor's algorithm solves in polynomial time on a
/// sufficiently large quantum computer. When such a machine exists, every
/// address whose public key has ever been revealed — which is every address that
/// has ever sent a transaction — can be forged at will.
///
/// Hash-based signatures are the one mature family that Shor does not touch.
/// Grover's algorithm gives only a quadratic speedup on preimage search, so a
/// 256-bit hash retains ~128 bits of security against a quantum adversary. That
/// is why NIST's SLH-DSA (FIPS 205, formerly SPHINCS+) is hash-based, and why
/// WOTS+ — SLH-DSA's own internal one-time signature — is the right primitive to
/// bring on-chain first: the EVM already has keccak256 as a cheap opcode, so no
/// new precompile and no consensus change is required to use it.
///
/// CONSTRUCTION
/// ------------
/// WOTS+ as specified in RFC 8391 §3.1, instantiated with keccak256 and
/// parameters n = 32 bytes, w = 16:
///
///   len1 = ceil(8n / lg(w))                 = 64 message digits (base 16)
///   len2 = floor(lg(len1(w-1)) / lg(w)) + 1 =  3 checksum digits
///   len  = len1 + len2                      = 67 hash chains
///
/// A signature is `len` chain values (67 x 32 = 2144 bytes). Verification walks
/// each chain forward from where the signature stopped to the chain's end and
/// checks that the resulting public key matches the committed one.
///
/// The chaining function applies a per-step key and bitmask derived from a public
/// seed (the "+" in WOTS+). This is not decoration: it reduces the security
/// requirement on the hash from collision resistance to second-preimage
/// resistance. That matters here specifically because quantum collision search
/// (Brassard-Hoyer-Tapp) scales as 2^(n/3) while quantum preimage search stays at
/// 2^(n/2) — so the bitmasked construction keeps the full ~128-bit quantum margin
/// that a collision-dependent construction would give up.
///
/// ONE-TIME — THIS IS LOAD-BEARING
/// -------------------------------
/// A WOTS+ key may sign EXACTLY ONE message, ever. Signing a second message
/// reveals lower chain positions for at least one digit, from which an attacker
/// can derive signatures for other messages by hashing forward. Verification here
/// is a pure function and CANNOT enforce single use. Every caller MUST record the
/// public key as consumed on first successful verification and refuse it after.
/// `QuantumGuard` shows the intended pattern.
///
/// SECURITY STATUS: unaudited. See docs/quantum/QUANTUM-RESISTANCE.md.
library WOTSPlus {
    /// @dev Winternitz parameter. w = 16 -> 4 bits per chain, 15 hashes max per chain.
    uint256 internal constant W = 16;
    /// @dev Message digits: a 256-bit digest carries 64 base-16 digits.
    uint256 internal constant LEN1 = 64;
    /// @dev Checksum digits: max checksum 64*15 = 960 < 2^12, so 3 base-16 digits.
    uint256 internal constant LEN2 = 3;
    /// @dev Total hash chains, and therefore signature elements.
    uint256 internal constant LEN = 67;
    /// @dev Signature size in bytes: LEN * 32.
    uint256 internal constant SIG_BYTES = 2144;

    /// @dev Domain separators keep the three hash roles disjoint, so a value
    ///      produced in one role can never be replayed as a value in another.
    bytes1 private constant D_F = 0x00; // chain step
    bytes1 private constant D_PRF = 0x03; // key / bitmask derivation
    bytes1 private constant D_PK = 0x07; // public-key compression

    error BadSignatureLength(uint256 got, uint256 want);

    /// @notice Verify a WOTS+ signature against a compressed public key.
    /// @param digest    The 32-byte message digest that was signed.
    /// @param sig       `LEN * 32` bytes: one chain value per digit.
    /// @param pubSeed   Public randomization seed bound to this key.
    /// @param pkHash    `compress(pubSeed, publicKey)` recorded when the key was armed.
    /// @return ok       True when the signature is valid for this digest and key.
    ///
    /// @dev Pure and constant-shape: it always walks every chain to its end, so
    ///      cost depends on the digest, never on secret material. The caller is
    ///      responsible for one-time enforcement (see the contract notice above).
    function verify(bytes32 digest, bytes memory sig, bytes32 pubSeed, bytes32 pkHash)
        internal
        pure
        returns (bool ok)
    {
        if (sig.length != SIG_BYTES) revert BadSignatureLength(sig.length, SIG_BYTES);

        uint8[LEN] memory digits = toDigits(digest);

        // Walk each chain from the signature's stopping point to the chain end.
        // Chain i was advanced digits[i] steps by the signer; the remaining
        // (W-1 - digits[i]) steps reconstruct the public-key element.
        bytes32[LEN] memory pk;
        for (uint256 i = 0; i < LEN; ++i) {
            bytes32 node;
            assembly ("memory-safe") {
                // sig is `bytes`: skip the 32-byte length prefix, then index.
                node := mload(add(add(sig, 0x20), mul(i, 0x20)))
            }
            pk[i] = chain(node, digits[i], W - 1, pubSeed, i);
        }

        return compress(pubSeed, pk) == pkHash;
    }

    /// @notice Compress a full WOTS+ public key to the single word stored on-chain.
    /// @dev Binding `pubSeed` into the commitment stops an attacker from pairing a
    ///      captured public key with a seed of their own choosing.
    function compress(bytes32 pubSeed, bytes32[LEN] memory pk) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(D_PK, pubSeed, pk));
    }

    /// @notice Advance a chain value from step `from` (inclusive) to `to` (exclusive).
    /// @dev The RFC 8391 chaining function. Each step derives a fresh key and
    ///      bitmask from (pubSeed, chain index, step index) so that no two steps
    ///      anywhere in the key ever share a hash input structure.
    ///
    ///      Written in assembly over two reusable scratch buffers. The equivalent
    ///      `abi.encodePacked` form allocates three fresh byte arrays per step and
    ///      costs ~510k gas to verify a signature; hashing out of fixed buffers
    ///      removes ~3000 allocations and their memory-expansion cost. The
    ///      hash inputs are byte-for-byte identical either way, which the
    ///      Python reference vectors in WOTSPlus.t.sol independently confirm.
    ///
    ///      Buffer layouts (byte offsets):
    ///        PRF at p : [0]=0x03  [1..32]=pubSeed  [33..34]=chainIndex  [35..36]=step  [37]=j
    ///        F   at q : [0]=0x00  [1..32]=key      [33..64]=x^mask
    function chain(bytes32 x, uint256 from, uint256 to, bytes32 pubSeed, uint256 chainIndex)
        internal
        pure
        returns (bytes32)
    {
        assembly ("memory-safe") {
            let p := mload(0x40)
            let q := add(p, 64)
            mstore(0x40, add(p, 160)) // reserve both buffers; never freed, scoped to the call

            // Fields constant for the whole chain are written once.
            mstore8(p, 0x03) // D_PRF
            mstore(add(p, 1), pubSeed)
            mstore8(add(p, 33), shr(8, chainIndex))
            mstore8(add(p, 34), chainIndex)
            mstore8(q, 0x00) // D_F

            for { let i := from } lt(i, to) { i := add(i, 1) } {
                mstore8(add(p, 35), shr(8, i))
                mstore8(add(p, 36), i)

                mstore8(add(p, 37), 0)
                let key := keccak256(p, 38)
                mstore8(add(p, 37), 1)
                let mask := keccak256(p, 38)

                mstore(add(q, 1), key)
                mstore(add(q, 33), xor(x, mask))
                x := keccak256(q, 65)
            }
        }
        return x;
    }

    /// @notice Expand a digest into the 67 base-16 digits that WOTS+ actually signs.
    /// @dev The checksum is what makes forgery hard. Chains only run forward, so an
    ///      attacker can always raise a message digit; the checksum digits are the
    ///      complement of the message digits, so raising any message digit lowers
    ///      the checksum — which would require running some chain BACKWARD.
    function toDigits(bytes32 digest) internal pure returns (uint8[LEN] memory digits) {
        uint256 csum = 0;
        for (uint256 i = 0; i < LEN1; ++i) {
            // Big-endian nibbles: high nibble of byte 0 is digit 0.
            uint8 d = uint8((uint256(digest) >> (252 - 4 * i)) & 0x0f);
            digits[i] = d;
            csum += (W - 1) - d;
        }
        // csum <= 64 * 15 = 960 < 2^12, so three base-16 digits hold it exactly.
        // This matches RFC 8391's left-shift-then-base_w for these parameters.
        digits[LEN1] = uint8((csum >> 8) & 0x0f);
        digits[LEN1 + 1] = uint8((csum >> 4) & 0x0f);
        digits[LEN1 + 2] = uint8(csum & 0x0f);
    }
}
