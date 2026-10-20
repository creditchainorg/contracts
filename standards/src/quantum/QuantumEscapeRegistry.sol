// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import { WOTSPlus } from "./WOTSPlus.sol";

/// @title QuantumEscapeRegistry — register a post-quantum escape key while ECDSA still holds
/// @notice Any account — an EOA, a Safe, a contract — records today a commitment to a
///         post-quantum key it holds, plus the address its assets should go to if it ever has
///         to escape. Once a quantum computer can forge secp256k1 signatures, an ECDSA signature
///         stops proving anything; a commitment made *before* that day is the one piece of
///         evidence of ownership that survives it.
///
/// WHAT THIS IS, AND WHAT IT IS NOT
/// --------------------------------
/// It is a registry and a coordination point. On its own it moves nothing. Contracts that hold
/// value (QuantumGuard-style vaults, guarded accounts, treasuries) read it to decide who may
/// recover, and a future network upgrade can read it to decide which accounts may migrate when
/// ECDSA-only spending is turned off. It does not make secp256k1 quantum-resistant.
///
/// WHY THE RULES ARE ASYMMETRIC
/// ----------------------------
/// The threat is an attacker who can forge this account's ECDSA signatures. So:
///   - ECDSA may register a commitment ONCE. Registering early wins.
///   - After that, the post-quantum key alone rotates it, immediately.
///   - ECDSA may only *propose* a replacement (for an owner who lost the PQ key), and it takes
///     effect after REPLACEMENT_DELAY. Any PQ rotation in the meantime cancels it. An attacker
///     with a forged ECDSA key therefore gets nothing while the real owner is watching.
///
/// SCHEMES
/// -------
///   1  WOTS+ over keccak256 (n=32, w=16)      verified here, ~250k gas; ONE-TIME: every
///                                              rotation must name the next key
///   2  ML-DSA-44  (FIPS 204)                  verified by precompile 0x12 (EIP-8355)
///   3  ML-DSA-65                              precompile 0x13
///   4  ML-DSA-87                              precompile 0x14
///   For WOTS+ the commitment is `WOTSPlus.compress(pubSeed, pk)`; for ML-DSA it is keccak256 of
///   the FIPS 204 encoded public key. On a chain without the EIP-8355 precompiles, ML-DSA keys
///   can be registered but not yet used to rotate: the call reverts with
///   {VerifierUnavailable}, never accepts.
///
/// @dev No owner, no upgrade, no funds. Deployed at one address on every EVM chain.
///      SECURITY STATUS: not yet audited.
contract QuantumEscapeRegistry {
    uint8 public constant WOTS_PLUS_KECCAK = 1;
    uint8 public constant ML_DSA_44 = 2;
    uint8 public constant ML_DSA_65 = 3;
    uint8 public constant ML_DSA_87 = 4;

    uint64 public constant REPLACEMENT_DELAY = 30 days;

    bytes32 public constant ROTATE_TYPEHASH = keccak256(
        "QuantumEscapeRotate(address account,uint64 rotation,uint8 scheme,bytes32 commitment,bytes32 pubSeed,address recovery)"
    );
    bytes32 private constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    struct Escape {
        uint8 scheme;
        bytes32 commitment;
        /// WOTS+ public randomisation seed; zero for ML-DSA.
        bytes32 pubSeed;
        /// Where this account's assets go if it has to escape. Chosen while ECDSA was trusted.
        address recovery;
        uint64 registeredAt;
        /// Number of PQ rotations so far. Bound into every rotation signature.
        uint64 rotation;
    }

    struct Pending {
        uint8 scheme;
        bytes32 commitment;
        bytes32 pubSeed;
        address recovery;
        uint64 effectiveAt;
    }

    mapping(address => Escape) private _escapes;
    mapping(address => Pending) private _pending;

    event EscapeRegistered(
        address indexed account, uint8 scheme, bytes32 commitment, address recovery
    );
    event EscapeRotated(
        address indexed account, uint64 rotation, uint8 scheme, bytes32 commitment, address recovery
    );
    event ReplacementProposed(
        address indexed account,
        uint8 scheme,
        bytes32 commitment,
        address recovery,
        uint64 effectiveAt
    );
    event ReplacementCancelled(address indexed account);
    event ReplacementFinalized(
        address indexed account, uint8 scheme, bytes32 commitment, address recovery
    );

    error AlreadyRegistered();
    error NotRegistered();
    error UnknownScheme();
    error ZeroCommitment();
    error ZeroRecovery();
    error BadQuantumSignature();
    error VerifierUnavailable();
    error NoPendingReplacement();
    error ReplacementNotDue(uint64 effectiveAt);
    error PublicKeyMismatch();

    // ───────────────────────────── ECDSA side ─────────────────────────────

    /// @notice Register this account's escape key. Possible exactly once; after that only the
    ///         post-quantum key itself can change it (or a delayed replacement, see below).
    function register(uint8 scheme, bytes32 commitment, bytes32 pubSeed, address recovery)
        external
    {
        if (_escapes[msg.sender].scheme != 0) revert AlreadyRegistered();
        _check(scheme, commitment, recovery);
        _escapes[msg.sender] = Escape({
            scheme: scheme,
            commitment: commitment,
            pubSeed: scheme == WOTS_PLUS_KECCAK ? pubSeed : bytes32(0),
            recovery: recovery,
            registeredAt: uint64(block.timestamp),
            rotation: 0
        });
        emit EscapeRegistered(msg.sender, scheme, commitment, recovery);
    }

    /// @notice For an owner who lost the post-quantum key: propose a new one with the ECDSA key.
    ///         It takes effect only after REPLACEMENT_DELAY, and any PQ rotation cancels it.
    function proposeReplacement(uint8 scheme, bytes32 commitment, bytes32 pubSeed, address recovery)
        external
    {
        if (_escapes[msg.sender].scheme == 0) revert NotRegistered();
        _check(scheme, commitment, recovery);
        uint64 effectiveAt = uint64(block.timestamp) + REPLACEMENT_DELAY;
        _pending[msg.sender] = Pending({
            scheme: scheme,
            commitment: commitment,
            pubSeed: scheme == WOTS_PLUS_KECCAK ? pubSeed : bytes32(0),
            recovery: recovery,
            effectiveAt: effectiveAt
        });
        emit ReplacementProposed(msg.sender, scheme, commitment, recovery, effectiveAt);
    }

    /// @notice The ECDSA key withdraws its own proposal.
    function cancelReplacement() external {
        if (_pending[msg.sender].effectiveAt == 0) revert NoPendingReplacement();
        delete _pending[msg.sender];
        emit ReplacementCancelled(msg.sender);
    }

    /// @notice Anyone may finalize a replacement once its delay has passed.
    function finalizeReplacement(address account) external {
        Pending memory p = _pending[account];
        if (p.effectiveAt == 0) revert NoPendingReplacement();
        if (block.timestamp < p.effectiveAt) revert ReplacementNotDue(p.effectiveAt);
        delete _pending[account];
        Escape storage e = _escapes[account];
        e.scheme = p.scheme;
        e.commitment = p.commitment;
        e.pubSeed = p.pubSeed;
        e.recovery = p.recovery;
        emit ReplacementFinalized(account, p.scheme, p.commitment, p.recovery);
    }

    // ───────────────────────────── post-quantum side ─────────────────────────────

    /// @notice Rotate `account`'s escape key, authorised by its current post-quantum key.
    /// @param publicKey For ML-DSA: the FIPS 204 encoded public key (its keccak256 must equal the
    ///        registered commitment). Ignored for WOTS+, where the commitment is the key.
    /// @param signature A signature over {rotationDigest} for the CURRENT key.
    /// @dev Permissionless to submit: the signature binds every new value, so a relayer can only
    ///      deliver what the key holder signed. Also cancels any pending ECDSA replacement.
    function rotate(
        address account,
        uint8 scheme,
        bytes32 commitment,
        bytes32 pubSeed,
        address recovery,
        bytes calldata publicKey,
        bytes calldata signature
    ) external {
        Escape storage e = _escapes[account];
        if (e.scheme == 0) revert NotRegistered();
        _check(scheme, commitment, recovery);
        bytes32 digest = rotationDigest(account, e.rotation, scheme, commitment, pubSeed, recovery);
        if (!_verify(e, publicKey, digest, signature)) revert BadQuantumSignature();

        uint64 next = e.rotation + 1;
        e.scheme = scheme;
        e.commitment = commitment;
        e.pubSeed = scheme == WOTS_PLUS_KECCAK ? pubSeed : bytes32(0);
        e.recovery = recovery;
        e.rotation = next;
        if (_pending[account].effectiveAt != 0) {
            delete _pending[account];
            emit ReplacementCancelled(account);
        }
        emit EscapeRotated(account, next, scheme, commitment, recovery);
    }

    // ───────────────────────────── views ─────────────────────────────

    function escapeOf(address account) external view returns (Escape memory) {
        return _escapes[account];
    }

    function pendingOf(address account) external view returns (Pending memory) {
        return _pending[account];
    }

    /// @notice What the current post-quantum key signs to rotate. EIP-712, bound to this chain and
    ///         this registry, and to the rotation counter so a signature can never be replayed.
    function rotationDigest(
        address account,
        uint64 rotation,
        uint8 scheme,
        bytes32 commitment,
        bytes32 pubSeed,
        address recovery
    ) public view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256("QuantumEscapeRegistry"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(ROTATE_TYPEHASH, account, rotation, scheme, commitment, pubSeed, recovery)
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    // ───────────────────────────── internals ─────────────────────────────

    function _check(uint8 scheme, bytes32 commitment, address recovery) private pure {
        if (scheme == 0 || scheme > ML_DSA_87) revert UnknownScheme();
        if (commitment == bytes32(0)) revert ZeroCommitment();
        if (recovery == address(0)) revert ZeroRecovery();
    }

    function _verify(
        Escape storage e,
        bytes calldata publicKey,
        bytes32 digest,
        bytes calldata signature
    ) private view returns (bool) {
        if (e.scheme == WOTS_PLUS_KECCAK) {
            if (signature.length != WOTSPlus.SIG_BYTES) return false;
            return WOTSPlus.verify(digest, signature, e.pubSeed, e.commitment);
        }
        if (keccak256(publicKey) != e.commitment) revert PublicKeyMismatch();
        // EIP-8355: input = pubkey ++ signature ++ message; exactly 32 bytes back, 1 = valid.
        address precompile = address(uint160(0x12 + (e.scheme - ML_DSA_44)));
        (bool ok, bytes memory ret) =
            precompile.staticcall(abi.encodePacked(publicKey, signature, digest));
        if (!ok || ret.length != 32) revert VerifierUnavailable();
        return abi.decode(ret, (uint256)) == 1;
    }
}
