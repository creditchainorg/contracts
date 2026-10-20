// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { QuantumEscapeRegistry } from "../../src/quantum/QuantumEscapeRegistry.sol";
import { WOTSPlusSigner } from "./WOTSPlusSigner.sol";

/// Stand-in for the EIP-8355 ML-DSA-44 precompile, for tests only: it parses the same input
/// layout (pubkey 1312 ++ signature 2420 ++ message) and returns the same 32-byte word, but its
/// "signature" is just keccak256(pubkey ++ message) in the first 32 bytes. Real ML-DSA is tested
/// against NIST vectors in the node.
contract FakeMlDsa44 {
    fallback(bytes calldata input) external returns (bytes memory) {
        if (input.length < 1312 + 2420) return abi.encode(uint256(0));
        bytes calldata pk = input[0:1312];
        bytes calldata sig = input[1312:1312 + 2420];
        bytes calldata message = input[1312 + 2420:];
        bool valid = bytes32(sig[0:32]) == keccak256(abi.encodePacked(pk, message));
        return abi.encode(valid ? uint256(1) : uint256(0));
    }
}

/// A broken verifier: answers with the wrong length.
contract ShortAnswer {
    fallback() external {
        assembly {
            return(0, 0)
        }
    }
}

contract QuantumEscapeRegistryTest is Test {
    QuantumEscapeRegistry reg;
    address alice = makeAddr("alice");
    address recovery = makeAddr("coldRecovery");
    address relayer = makeAddr("relayer");

    bytes32 constant SEED1 = keccak256("secret-1");
    bytes32 constant SEED2 = keccak256("secret-2");
    bytes32 constant PUB1 = keccak256("pub-1");
    bytes32 constant PUB2 = keccak256("pub-2");
    uint8 constant WOTS = 1;
    uint8 constant MLDSA44 = 2;

    function setUp() public {
        reg = new QuantumEscapeRegistry();
    }

    function _registerWots() internal returns (bytes32 pk1) {
        pk1 = WOTSPlusSigner.publicKeyHash(SEED1, PUB1);
        vm.prank(alice);
        reg.register(WOTS, pk1, PUB1, recovery);
    }

    function test_register_once() public {
        bytes32 pk1 = _registerWots();
        QuantumEscapeRegistry.Escape memory e = reg.escapeOf(alice);
        assertEq(e.scheme, WOTS);
        assertEq(e.commitment, pk1);
        assertEq(e.pubSeed, PUB1);
        assertEq(e.recovery, recovery);
        assertEq(e.rotation, 0);

        // A forged ECDSA key later cannot overwrite it.
        vm.prank(alice);
        vm.expectRevert(QuantumEscapeRegistry.AlreadyRegistered.selector);
        reg.register(WOTS, keccak256("attacker"), PUB2, makeAddr("thief"));
    }

    function test_register_validates() public {
        vm.startPrank(alice);
        vm.expectRevert(QuantumEscapeRegistry.UnknownScheme.selector);
        reg.register(0, bytes32(uint256(1)), bytes32(0), recovery);
        vm.expectRevert(QuantumEscapeRegistry.UnknownScheme.selector);
        reg.register(5, bytes32(uint256(1)), bytes32(0), recovery);
        vm.expectRevert(QuantumEscapeRegistry.ZeroCommitment.selector);
        reg.register(WOTS, bytes32(0), PUB1, recovery);
        vm.expectRevert(QuantumEscapeRegistry.ZeroRecovery.selector);
        reg.register(WOTS, bytes32(uint256(1)), PUB1, address(0));
        vm.stopPrank();
    }

    function test_wots_rotation_chainsToTheNextKey() public {
        _registerWots();
        bytes32 pk2 = WOTSPlusSigner.publicKeyHash(SEED2, PUB2);
        address newRecovery = makeAddr("newCold");
        bytes32 digest = reg.rotationDigest(alice, 0, WOTS, pk2, PUB2, newRecovery);
        bytes memory sig = WOTSPlusSigner.sign(digest, SEED1, PUB1);

        vm.prank(relayer); // anyone may deliver it
        reg.rotate(alice, WOTS, pk2, PUB2, newRecovery, "", sig);

        QuantumEscapeRegistry.Escape memory e = reg.escapeOf(alice);
        assertEq(e.commitment, pk2);
        assertEq(e.pubSeed, PUB2);
        assertEq(e.recovery, newRecovery);
        assertEq(e.rotation, 1);

        // The consumed key and its signature are worthless now.
        vm.expectRevert(QuantumEscapeRegistry.BadQuantumSignature.selector);
        reg.rotate(alice, WOTS, pk2, PUB2, newRecovery, "", sig);

        // The next key works for the next rotation.
        bytes32 pk3 = WOTSPlusSigner.publicKeyHash(keccak256("secret-3"), PUB1);
        bytes memory sig2 = WOTSPlusSigner.sign(
            reg.rotationDigest(alice, 1, WOTS, pk3, PUB1, recovery), SEED2, PUB2
        );
        reg.rotate(alice, WOTS, pk3, PUB1, recovery, "", sig2);
        assertEq(reg.escapeOf(alice).rotation, 2);
    }

    function test_wots_signatureBindsEveryField() public {
        _registerWots();
        bytes32 pk2 = WOTSPlusSigner.publicKeyHash(SEED2, PUB2);
        bytes memory sig = WOTSPlusSigner.sign(
            reg.rotationDigest(alice, 0, WOTS, pk2, PUB2, recovery), SEED1, PUB1
        );
        // A relayer swaps in its own recovery address.
        vm.expectRevert(QuantumEscapeRegistry.BadQuantumSignature.selector);
        reg.rotate(alice, WOTS, pk2, PUB2, relayer, "", sig);
        // ...or its own next key.
        vm.expectRevert(QuantumEscapeRegistry.BadQuantumSignature.selector);
        reg.rotate(alice, WOTS, keccak256("mine"), PUB2, recovery, "", sig);
        // ...or replays it against someone else.
        vm.prank(relayer);
        reg.register(WOTS, WOTSPlusSigner.publicKeyHash(SEED1, PUB1), PUB1, recovery);
        vm.expectRevert(QuantumEscapeRegistry.BadQuantumSignature.selector);
        reg.rotate(relayer, WOTS, pk2, PUB2, recovery, "", sig);
    }

    function test_wots_wrongKeyRejected() public {
        _registerWots();
        bytes32 pk2 = WOTSPlusSigner.publicKeyHash(SEED2, PUB2);
        bytes memory sig = WOTSPlusSigner.sign(
            reg.rotationDigest(alice, 0, WOTS, pk2, PUB2, recovery), SEED2, PUB2
        );
        vm.expectRevert(QuantumEscapeRegistry.BadQuantumSignature.selector);
        reg.rotate(alice, WOTS, pk2, PUB2, recovery, "", sig);
    }

    function test_wots_wrongLengthIsInvalidNotAPanic() public {
        _registerWots();
        vm.expectRevert(QuantumEscapeRegistry.BadQuantumSignature.selector);
        reg.rotate(alice, WOTS, keccak256("x"), PUB2, recovery, "", hex"00");
    }

    function test_rotationDigest_isChainBound() public {
        bytes32 here = reg.rotationDigest(alice, 0, WOTS, bytes32(uint256(1)), PUB1, recovery);
        vm.chainId(block.chainid + 1);
        assertTrue(reg.rotationDigest(alice, 0, WOTS, bytes32(uint256(1)), PUB1, recovery) != here);
    }

    function test_unregisteredCannotRotate() public {
        vm.expectRevert(QuantumEscapeRegistry.NotRegistered.selector);
        reg.rotate(alice, WOTS, keccak256("x"), PUB2, recovery, "", "");
    }

    // ───────────────────────────── delayed ECDSA replacement ─────────────────────────────

    function test_replacement_waitsForTheDelay() public {
        _registerWots();
        vm.prank(alice);
        reg.proposeReplacement(WOTS, keccak256("new"), PUB2, recovery);
        uint64 due = reg.pendingOf(alice).effectiveAt;
        assertEq(due, block.timestamp + 30 days);
        vm.expectRevert(
            abi.encodeWithSelector(QuantumEscapeRegistry.ReplacementNotDue.selector, due)
        );
        reg.finalizeReplacement(alice);
        vm.warp(due);
        reg.finalizeReplacement(alice);
        assertEq(reg.escapeOf(alice).commitment, keccak256("new"));
        assertEq(reg.pendingOf(alice).effectiveAt, 0);
    }

    function test_replacement_cancelledByQuantumRotation() public {
        _registerWots();
        // An attacker with a forged ECDSA key proposes its own key.
        vm.prank(alice);
        reg.proposeReplacement(WOTS, keccak256("attacker"), PUB2, makeAddr("thief"));
        // The real owner answers with the post-quantum key.
        bytes32 pk2 = WOTSPlusSigner.publicKeyHash(SEED2, PUB2);
        bytes memory sig = WOTSPlusSigner.sign(
            reg.rotationDigest(alice, 0, WOTS, pk2, PUB2, recovery), SEED1, PUB1
        );
        reg.rotate(alice, WOTS, pk2, PUB2, recovery, "", sig);
        assertEq(reg.pendingOf(alice).effectiveAt, 0);
        vm.warp(block.timestamp + 31 days);
        vm.expectRevert(QuantumEscapeRegistry.NoPendingReplacement.selector);
        reg.finalizeReplacement(alice);
        assertEq(reg.escapeOf(alice).commitment, pk2);
    }

    function test_replacement_ownerCanWithdrawIt() public {
        _registerWots();
        vm.startPrank(alice);
        reg.proposeReplacement(WOTS, keccak256("new"), PUB2, recovery);
        reg.cancelReplacement();
        vm.expectRevert(QuantumEscapeRegistry.NoPendingReplacement.selector);
        reg.cancelReplacement();
        vm.stopPrank();
    }

    function test_replacement_needsRegistration() public {
        vm.prank(alice);
        vm.expectRevert(QuantumEscapeRegistry.NotRegistered.selector);
        reg.proposeReplacement(WOTS, keccak256("new"), PUB2, recovery);
    }

    // ───────────────────────────── ML-DSA via EIP-8355 ─────────────────────────────

    function _mldsaKey() internal pure returns (bytes memory pk) {
        pk = new bytes(1312);
        for (uint256 i = 0; i < 1312; i++) {
            pk[i] = bytes1(uint8(i * 7));
        }
    }

    function _fakeSig(bytes memory pk, bytes32 digest) internal pure returns (bytes memory sig) {
        sig = new bytes(2420);
        bytes32 tag = keccak256(abi.encodePacked(pk, digest));
        for (uint256 i = 0; i < 32; i++) {
            sig[i] = tag[i];
        }
    }

    function test_mldsa_withoutPrecompile_failsClosed() public {
        bytes memory pk = _mldsaKey();
        vm.prank(alice);
        reg.register(MLDSA44, keccak256(pk), bytes32(0), recovery);
        bytes32 digest = reg.rotationDigest(alice, 0, WOTS, keccak256("n"), PUB2, recovery);
        bytes memory sig = _fakeSig(pk, digest);
        vm.expectRevert(QuantumEscapeRegistry.VerifierUnavailable.selector);
        reg.rotate(alice, WOTS, keccak256("n"), PUB2, recovery, pk, sig);
    }

    function test_mldsa_rotationThroughPrecompile() public {
        vm.etch(address(0x12), address(new FakeMlDsa44()).code);
        bytes memory pk = _mldsaKey();
        vm.prank(alice);
        reg.register(MLDSA44, keccak256(pk), keccak256("ignored"), recovery);
        assertEq(reg.escapeOf(alice).pubSeed, bytes32(0), "ML-DSA keys carry no seed");

        bytes32 next = WOTSPlusSigner.publicKeyHash(SEED2, PUB2);
        bytes32 digest = reg.rotationDigest(alice, 0, WOTS, next, PUB2, recovery);
        bytes memory bad = _fakeSig(pk, keccak256("other message"));
        vm.expectRevert(QuantumEscapeRegistry.BadQuantumSignature.selector);
        reg.rotate(alice, WOTS, next, PUB2, recovery, pk, bad);

        bytes memory otherPk = _mldsaKey();
        otherPk[0] = 0xff;
        vm.expectRevert(QuantumEscapeRegistry.PublicKeyMismatch.selector);
        reg.rotate(alice, WOTS, next, PUB2, recovery, otherPk, _fakeSig(otherPk, digest));

        reg.rotate(alice, WOTS, next, PUB2, recovery, pk, _fakeSig(pk, digest));
        assertEq(reg.escapeOf(alice).scheme, WOTS);
        assertEq(reg.escapeOf(alice).commitment, next);
    }

    function test_mldsa_malformedVerifierAnswerFailsClosed() public {
        vm.etch(address(0x12), address(new ShortAnswer()).code);
        bytes memory pk = _mldsaKey();
        vm.prank(alice);
        reg.register(MLDSA44, keccak256(pk), bytes32(0), recovery);
        bytes32 digest = reg.rotationDigest(alice, 0, WOTS, keccak256("n"), PUB2, recovery);
        bytes memory sig = _fakeSig(pk, digest);
        vm.expectRevert(QuantumEscapeRegistry.VerifierUnavailable.selector);
        reg.rotate(alice, WOTS, keccak256("n"), PUB2, recovery, pk, sig);
    }
}
