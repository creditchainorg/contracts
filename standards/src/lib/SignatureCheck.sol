// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.24;

/// @title SignatureCheck
/// @notice Is `signature` a valid signature by `signer` over `digest`?
///
/// Tries ECDSA first, then ERC-1271. That order matters on chains with EIP-7702: a delegated EOA
/// has code, but its own key still signs, and its delegate may not implement ERC-1271. Asking the
/// code first would reject a perfectly good EOA signature.
library SignatureCheck {
    bytes4 internal constant ERC1271_MAGIC = 0x1626ba7e;
    /// secp256k1n / 2. Signatures above it are the malleable twin of one below it.
    uint256 private constant HALF_N =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    function isValid(address signer, bytes32 digest, bytes memory signature)
        internal
        view
        returns (bool)
    {
        if (signer == address(0)) return false;
        if (signature.length == 65 && recover(digest, signature) == signer) return true;
        if (signer.code.length == 0) return false;
        (bool ok, bytes memory ret) =
            signer.staticcall(abi.encodeWithSelector(ERC1271_MAGIC, digest, signature));
        return ok && ret.length >= 32 && abi.decode(ret, (bytes4)) == ERC1271_MAGIC;
    }

    /// @return The signer, or address(0) for a malformed, malleable or invalid signature.
    function recover(bytes32 digest, bytes memory signature) internal pure returns (address) {
        if (signature.length != 65) return address(0);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        if (uint256(s) > HALF_N) return address(0);
        if (v < 27) v += 27;
        if (v != 27 && v != 28) return address(0);
        return ecrecover(digest, v, r, s);
    }
}
