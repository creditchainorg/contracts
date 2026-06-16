# Security & Threat Model — Agent Finance

Scope: `AgentSpendVault.sol` (the ERC-AGM reference implementation) and its
interface `IAgentSpendMandate.sol`. This document states what the contracts
defend, what they assume, the threats considered, and the residual risks a user
or integrator must accept. It is written to be the starting point for an
external audit, not a substitute for one.

> **Status:** not yet externally audited. CCC on testnet has no monetary value.
> Do not custody material value until an audit is complete and `MAINNET_ACK`
> has been lifted on the chain side.

## 1. Security model

A mandate delegates **bounded, revocable spending authority** — never custody —
from an `owner` to an `agent`. The contract is the trust boundary: the agent
acts autonomously, but every payment is checked against the rails the owner set,
on-chain, before any value moves.

**Core property (proven by invariant tests):** the vault is always solvent —
`address(vault).balance == Σ mandate.balance` over any sequence of actions. No
operation creates, destroys, or strands value. See
`test/AgentSpendVault.invariants.t.sol` (256 runs × depth 50 each).

## 2. Trust assumptions

- The **owner** is trusted with their own funds; they choose the agent and the
  rails and can revoke at any time.
- The **agent's key** is *not* trusted beyond its rails. Compromise is assumed
  possible; the design bounds the blast radius rather than preventing misuse.
- The **chain** orders and executes transactions honestly (standard EVM
  liveness/safety). Validator-level censorship or reorgs are out of scope here.
- **No privileged operator exists.** There is no admin, owner-of-owners, pause,
  or upgrade path. Not even the deployer can move a mandate's funds.

## 3. Assets at risk

| Asset | Held where | Who can move it |
|---|---|---|
| A mandate's CCC balance | in the vault, per mandate | the mandate's agent (via `spend`, within rails) and its owner (`withdraw`/`revoke`) — nobody else |
| Spending authority | encoded in the mandate's rails | only the owner can change rails / revoke |

## 4. Roles & privileges

| Action | owner | agent | anyone |
|---|:---:|:---:|:---:|
| `createMandate` | ✓ (becomes owner) | — | ✓ (becomes owner of the new mandate) |
| `fundMandate` | ✓ | ✓ | ✓ (top-ups welcome; funds still owner-controlled) |
| `allowRecipient` | ✓ | — | — |
| `spend` | — | ✓ | — |
| `withdraw` / `revoke` | ✓ | — | — |

## 5. Threats considered & mitigations

| # | Threat | Mitigation |
|---|---|---|
| T1 | **Reentrancy** via a malicious recipient/agent contract re-entering `spend`/`revoke`/`withdraw` to exceed rails or double-withdraw | `nonReentrant` guard on every value-moving function; checks-effects-interactions (state updated before the external `call`). Covered by `test_reentrancyResisted`. |
| T2 | **Agent overspends** (compromised or buggy agent) | Budget cap, per-tx max, and rolling-window rate limit all enforced in `spend`; each reverts with a typed error and moves nothing. Proven by example + invariant (`invariant_spentWithinBudget`). |
| T3 | **Agent pays an attacker-controlled address** | Optional recipient allowlist; with it enabled, `spend` reverts `RecipientNotAllowed` for any non-allowlisted payee. |
| T4 | **Stale/abandoned agent keeps spending** | Per-mandate `expiry`; after it, `spend` reverts `MandateInactive`. |
| T5 | **Non-owner tries to drain/seize** (incl. the deployer) | All fund-moving owner actions check `msg.sender == owner`; no global admin path exists. `test_onlyAgentCanSpend`, `allowlist` owner-only checks. |
| T6 | **Value created or destroyed by arithmetic/accounting bugs** | Solidity ≥0.8 checked arithmetic; solvency + conservation invariants (`invariant_solvency`, `invariant_valueConservation`) hold over fuzzed sequences. |
| T7 | **Failed native transfer leaves inconsistent state** | Transfer return value checked; on failure the whole call reverts (`TransferFailed`), rolling back the effects. |
| T8 | **Window rate-limit bypass** by timing | Window resets lazily and accounts `windowSpent` before transfer; `test_rollingWindowLimitAndReset`. Note the limitation in §6. |
| T9 | **Wrong contract verified / source mismatch** | Deployments are verified by exact `deployedBytecode` match (`script/verify-contract.sh`); the explorer shows the matching source. |

## 6. Known limitations & residual risk

- **Agent-key compromise is bounded, not eliminated.** A compromised agent can
  still spend up to its rails until the owner revokes. Owners should scope
  budget, per-tx, window, allowlist, and expiry to the smallest workable values.
- **The rolling window is approximate by design.** It resets lazily on the first
  spend after the window elapses; it is a gas-cheap rate limit, not a precise
  sliding window, and must not be relied on as one.
- **Funding a revoked mandate.** Anyone may `fundMandate`; CCC added to a revoked
  mandate is never spendable by the agent and remains recoverable by the owner
  via `withdraw`. It is not lost, but senders should check mandate state first.
- **Recipient griefing.** A recipient contract that reverts on receipt will fail
  that `spend` (`TransferFailed`); the agent should avoid such recipients or the
  owner should not allowlist them.
- **No ERC-165 in the reference impl yet.** Interface discovery is by ABI, not
  `supportsInterface`; planned.
- **Off-chain enumeration.** `myMandates`-style listing iterates ids on-chain in
  the wallet; production integrators should index `MandateCreated` events.

## 7. Verification evidence

- **18 Foundry tests pass:** 13 example (incl. repelled reentrancy) + 4 invariant
  properties over ~12,800 randomized sequences each + 1 ERC-AGM conformance test.
- **Gas:** `spend` ≈ 42k avg (warm ≈ 29k) — suitable for high-frequency M2M use.
- **Deployments source-verified** on the public testnet by exact bytecode match.

## 8. Deployment & key management

- Owners should hold mandate-owner keys in hardware/secure storage; the owner key
  is the only recovery path for a misbehaving agent.
- Agent keys are operational and lower-trust by design, but compromise still
  costs up to the rails — rotate and revoke proactively.
- The chain’s mainnet remains gated (`MAINNET_ACK`) until launch; these contracts
  should be re-reviewed and audited against the final mainnet parameters.

## 9. Responsible disclosure

Report suspected vulnerabilities privately to **security@openibank.com** (or the
contact published on https://www.creditchain.org). Please include a minimal
reproduction and the affected commit/deployment address. Do not open public
issues or exploit live deployments. A coordinated-disclosure window will be
agreed before any public write-up; a bug-bounty opens with the PoS testnet
(see `ECOSYSTEM-MASTERPLAN.md` Phase 3).
