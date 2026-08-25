// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { WOTSPlus } from "../../src/quantum/WOTSPlus.sol";

/// @notice TEST-ONLY WOTS+ key generation and signing.
///
/// NEVER use this on-chain or in production. Signing requires the secret key, and
/// anything a contract touches is public — a real guardian key is generated and
/// kept off-chain (see reference/wotsplus.py). This exists so tests can produce
/// signatures over digests that depend on runtime values such as `block.chainid`
/// and a freshly deployed guard's address, which fixed vectors cannot cover.
///
/// `WOTSPlusSignerTest.test_matches_python_reference` pins this implementation to
/// the Python reference, so signatures it produces are the real construction and
/// not merely something the verifier happens to accept.
library WOTSPlusSigner {
    bytes1 private constant D_SK = 0x04;

    /// @dev Derive the 67 chain starts from one secret seed.
    function secretKey(bytes32 secretSeed) internal pure returns (bytes32[67] memory sk) {
        for (uint256 i = 0; i < WOTSPlus.LEN; ++i) {
            sk[i] = keccak256(abi.encodePacked(D_SK, secretSeed, uint16(i)));
        }
    }

    /// @dev Run every chain to its end to get the public key, then compress it.
    function publicKeyHash(bytes32 secretSeed, bytes32 pubSeed) internal pure returns (bytes32) {
        bytes32[67] memory sk = secretKey(secretSeed);
        bytes32[67] memory pk;
        for (uint256 i = 0; i < WOTSPlus.LEN; ++i) {
            pk[i] = WOTSPlus.chain(sk[i], 0, WOTSPlus.W - 1, pubSeed, i);
        }
        return WOTSPlus.compress(pubSeed, pk);
    }

    /// @dev Stop each chain at its message digit — the signature IS those stopping points.
    function sign(bytes32 digest, bytes32 secretSeed, bytes32 pubSeed) internal pure returns (bytes memory sig) {
        bytes32[67] memory sk = secretKey(secretSeed);
        uint8[67] memory digits = WOTSPlus.toDigits(digest);
        sig = new bytes(WOTSPlus.SIG_BYTES);
        for (uint256 i = 0; i < WOTSPlus.LEN; ++i) {
            bytes32 v = WOTSPlus.chain(sk[i], 0, digits[i], pubSeed, i);
            assembly { mstore(add(add(sig, 0x20), mul(i, 0x20)), v) }
        }
    }
}
