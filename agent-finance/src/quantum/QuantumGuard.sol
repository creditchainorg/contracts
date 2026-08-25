// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { WOTSPlus } from "./WOTSPlus.sol";
import { IAgentSpendMandate } from "../IAgentSpendMandate.sol";

/// @title QuantumGuard — a break-glass authority that survives a broken ECDSA key
/// @notice Holds funds and drives ERC-AGM mandates on behalf of an owner, under two
///         separate authorities: a normal-operations ECDSA controller, and a
///         post-quantum guardian that can override it.
///
/// THE THREAT, STATED HONESTLY
/// --------------------------
/// Shor's algorithm recovers a secp256k1 private key from its public key. Every
/// EVM address that has ever sent a transaction has published its public key, so
/// on the day a cryptographically-relevant quantum computer exists, those keys
/// are forgeable. Adding a post-quantum key next to an ECDSA key does NOT by
/// itself help: if both can do the same things, the attacker simply uses the one
/// they broke.
///
/// A break-glass key is only worth having if it can do something the ECDSA key
/// CANNOT. That asymmetry is the entire design of this contract:
///
///   controller (ECDSA)         guardian (post-quantum, hash-based)
///   ------------------         ----------------------------------
///   create mandates            revoke every mandate
///   fund mandates              pull all mandate balances back
///   allowlist recipients       sweep the full balance to `recoveryAddress`
///                              replace the controller
///   BOUNDED by a rolling       NOT bounded
///   outflow limit
///   CANNOT withdraw
///   CANNOT change controller
///   CANNOT change recovery addr
///
/// So an attacker holding a forged controller key cannot withdraw anything, cannot
/// redirect recovery, and cannot exceed the outflow limit committed when the
/// guardian was armed. The worst case degrades from "instant total loss" to "a
/// bounded leak, then guaranteed recovery". That is a real security property, and
/// it is the honest limit of what this contract claims.
///
/// WHY THE RECOVERY ADDRESS IS COMMITTED AT ARM TIME
/// ------------------------------------------------
/// A break-glass signature is public the moment it reaches the mempool, so it must
/// be assumed stolen. Because the destination was fixed when the key was armed and
/// is bound into the signed digest, a stolen signature can only do the one thing
/// the owner already wanted: move funds to the owner's own recovery address. Anyone
/// may relay it; nobody can redirect it. Front-running is therefore harmless here
/// by construction rather than by mitigation.
///
/// ONE-TIME, AND ENFORCED HERE
/// ---------------------------
/// WOTS+ keys sign exactly once; a second signature leaks enough to forge. The
/// library cannot enforce that because verification is pure, so this contract does:
/// the guardian is marked consumed before any external call, and a consumed
/// guardian is rejected forever after.
///
/// SECURITY STATUS: unaudited. Test CCC has no monetary value.
contract QuantumGuard {
    // ── roles and state ──────────────────────────────────────────────────────

    /// @notice Day-to-day ECDSA authority. Deliberately limited (see table above).
    address public controller;

    /// @notice Where a break-glass sends everything. Fixed when the guardian is armed.
    address public recoveryAddress;

    /// @notice The ERC-AGM vault this guard operates on.
    IAgentSpendMandate public immutable vault;

    struct Guardian {
        bytes32 pkHash; // commitment to the WOTS+ public key
        bytes32 pubSeed; // public randomisation seed
        uint64 armedAt;
        bool consumed; // one-time: true after a successful break-glass
    }

    Guardian public guardian;

    /// @notice Rolling cap on how much the controller may push into mandates.
    uint256 public outflowLimit;
    uint64 public outflowWindow;
    uint64 public windowStart;
    uint256 public windowOutflow;

    /// @notice Set by break-glass. A frozen guard accepts no controller action ever again.
    bool public frozen;

    /// @notice Mandates this guard created, so break-glass can sweep them all.
    uint256[] public mandateIds;

    // ── events ───────────────────────────────────────────────────────────────

    event GuardianArmed(bytes32 indexed pkHash, address indexed recoveryAddress, uint256 outflowLimit, uint64 outflowWindow);
    event MandateOpened(uint256 indexed mandateId, address indexed agent, uint256 amount);
    event BreakGlass(bytes32 indexed pkHash, address indexed recoveryAddress, uint256 swept, uint256 mandatesRevoked);
    event ControllerRotated(address indexed from, address indexed to);

    // ── errors ───────────────────────────────────────────────────────────────

    error NotController();
    error AlreadyArmed();
    error NotArmed();
    error GuardianConsumed();
    error Frozen();
    error OutflowExceeded(uint256 requested, uint256 remaining);
    error InvalidQuantumSignature();
    error ZeroAddress();
    error SweepFailed();

    // ── construction ─────────────────────────────────────────────────────────

    constructor(address vault_, address controller_) {
        if (vault_ == address(0) || controller_ == address(0)) revert ZeroAddress();
        vault = IAgentSpendMandate(vault_);
        controller = controller_;
    }

    receive() external payable { }

    modifier onlyController() {
        if (msg.sender != controller) revert NotController();
        if (frozen) revert Frozen();
        _;
    }

    // ── arming the post-quantum guardian ─────────────────────────────────────

    /// @notice Commit to a post-quantum guardian key and the terms it enforces.
    /// @param pkHash    `WOTSPlus.compress(pubSeed, publicKey)`, computed off-chain.
    /// @param pubSeed   Public randomisation seed for the key.
    /// @param recovery  Where a break-glass will send everything. Immutable once armed.
    /// @param limit     Maximum the controller may push into mandates per window.
    /// @param window    Length of the rolling outflow window, in seconds.
    ///
    /// @dev Armable exactly once. Re-arming is deliberately impossible: if the
    ///      controller key were forged, the attacker's first move would otherwise be
    ///      to re-arm with a guardian of their own and lock the real owner out. A
    ///      fresh guardian therefore requires a fresh QuantumGuard.
    ///
    ///      Only the commitment is ever on-chain. The WOTS+ secret key is generated
    ///      and stored off-chain — see reference/wotsplus.py — and the public key is
    ///      revealed only in the single break-glass signature.
    function armGuardian(bytes32 pkHash, bytes32 pubSeed, address recovery, uint256 limit, uint64 window)
        external
        onlyController
    {
        if (guardian.pkHash != bytes32(0)) revert AlreadyArmed();
        if (recovery == address(0)) revert ZeroAddress();
        if (pkHash == bytes32(0)) revert ZeroAddress();

        guardian = Guardian({ pkHash: pkHash, pubSeed: pubSeed, armedAt: uint64(block.timestamp), consumed: false });
        recoveryAddress = recovery;
        outflowLimit = limit;
        outflowWindow = window;
        windowStart = uint64(block.timestamp);

        emit GuardianArmed(pkHash, recovery, limit, window);
    }

    // ── normal operations (bounded ECDSA authority) ──────────────────────────

    /// @notice Open a mandate on the vault, owned by this guard, funded from its balance.
    /// @dev Counts against the rolling outflow limit. This is the ONLY way value
    ///      leaves the guard under controller authority, which is what bounds the
    ///      damage a forged controller key can do.
    function openMandate(
        address agent,
        uint256 budget,
        uint256 perTxMax,
        uint256 windowLimit,
        uint64 windowSeconds,
        uint64 expiry,
        bool allowlistEnabled,
        uint256 fundAmount
    ) external onlyController returns (uint256 mandateId) {
        if (!isArmed()) revert NotArmed();
        _chargeOutflow(fundAmount);

        mandateId = vault.createMandate{ value: fundAmount }(
            agent, budget, perTxMax, windowLimit, windowSeconds, expiry, allowlistEnabled
        );
        mandateIds.push(mandateId);
        emit MandateOpened(mandateId, agent, fundAmount);
    }

    /// @notice Add funds to a mandate this guard owns. Counts against the outflow limit.
    function fundMandate(uint256 mandateId, uint256 amount) external onlyController {
        _chargeOutflow(amount);
        vault.fundMandate{ value: amount }(mandateId);
    }

    /// @notice Allowlist a recipient on a mandate this guard owns.
    /// @dev Moves no value, so it is not charged against the outflow limit.
    function allowRecipient(uint256 mandateId, address recipient, bool allowed) external onlyController {
        vault.allowRecipient(mandateId, recipient, allowed);
    }

    /// @dev Rolling window. The window resets lazily on first use after it lapses,
    ///      so an idle guard does not accumulate unused allowance.
    function _chargeOutflow(uint256 amount) private {
        if (outflowWindow > 0 && block.timestamp >= windowStart + outflowWindow) {
            windowStart = uint64(block.timestamp);
            windowOutflow = 0;
        }
        uint256 used = windowOutflow + amount;
        if (used > outflowLimit) revert OutflowExceeded(amount, outflowLimit - windowOutflow);
        windowOutflow = used;
    }

    // ── break glass (post-quantum authority) ─────────────────────────────────

    /// @notice The digest a guardian signs to trigger recovery.
    /// @dev Binds the chain id and this contract's address so a signature can never
    ///      be replayed onto another chain or another guard, and binds the recovery
    ///      address so a signature observed in the mempool cannot be repurposed.
    ///      No nonce is needed: the key is one-time and burned on use.
    function breakGlassDigest() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                "CreditChain/QuantumGuard/breakGlass/v1", block.chainid, address(this), recoveryAddress, guardian.pkHash
            )
        );
    }

    /// @notice Revoke everything, pull all funds back, sweep to `recoveryAddress`,
    ///         and hand control to it — authorised by a post-quantum signature.
    /// @param sig The 2144-byte WOTS+ signature over `breakGlassDigest()`.
    ///
    /// @dev Callable by ANYONE holding a valid signature. That is intentional: in a
    ///      recovery the owner may have no working key and no gas, so a relayer must
    ///      be able to submit on their behalf. It is safe because the destination is
    ///      fixed and signed.
    ///
    ///      Ordering matters: the guardian is consumed and the guard frozen BEFORE
    ///      any external call, so a hostile vault cannot re-enter into a second
    ///      break-glass and replay the one-time key.
    function breakGlass(bytes calldata sig) external {
        Guardian memory g = guardian;
        if (g.pkHash == bytes32(0)) revert NotArmed();
        if (g.consumed) revert GuardianConsumed();

        if (!WOTSPlus.verify(breakGlassDigest(), sig, g.pubSeed, g.pkHash)) {
            revert InvalidQuantumSignature();
        }

        // Burn the one-time key and freeze controller authority first.
        guardian.consumed = true;
        frozen = true;

        address recovery = recoveryAddress;
        uint256 revoked = _drainMandates();

        uint256 balance = address(this).balance;
        (bool sent,) = recovery.call{ value: balance }("");
        if (!sent) revert SweepFailed();

        address previous = controller;
        controller = recovery;

        emit ControllerRotated(previous, recovery);
        emit BreakGlass(g.pkHash, recovery, balance, revoked);
    }

    /// @dev Revoke every mandate and pull its unspent balance back into the guard.
    ///      Failures are tolerated per-mandate: one already-revoked or hostile
    ///      mandate must never be able to block recovery of all the others.
    function _drainMandates() private returns (uint256 revoked) {
        uint256 n = mandateIds.length;
        for (uint256 i = 0; i < n; ++i) {
            uint256 id = mandateIds[i];
            try vault.revoke(id) {
                revoked++;
            } catch { }
            try vault.mandate(id) returns (IAgentSpendMandate.Mandate memory m) {
                if (m.balance > 0) {
                    try vault.withdraw(id, m.balance) { } catch { }
                }
            } catch { }
        }
    }

    // ── views ────────────────────────────────────────────────────────────────

    function isArmed() public view returns (bool) {
        return guardian.pkHash != bytes32(0) && !guardian.consumed;
    }

    function mandateCount() external view returns (uint256) {
        return mandateIds.length;
    }

    /// @notice How much the controller may still push out in the current window.
    function outflowRemaining() external view returns (uint256) {
        if (outflowWindow > 0 && block.timestamp >= windowStart + outflowWindow) return outflowLimit;
        return outflowLimit - windowOutflow;
    }
}
