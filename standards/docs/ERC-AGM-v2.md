---
title: Agent Spending Mandate, version 2 (ERC-AGM v2)
description: A chain-enforced, bounded, revocable spending mandate an owner grants to an autonomous agent, for any asset on any EVM chain.
author: CreditChain Research Team
status: Draft
type: Standards Track
category: ERC
created: 2026-10-20
requires: 165, 712, 1271
---

## Abstract

An owner funds a *mandate* in the chain's native coin or any ERC-20 and names an *agent*. The agent
pays recipients on its own, and the contract enforces, on every payment: a lifetime budget, a
per-payment maximum, a rolling-window rate limit, an optional recipient allowlist, an expiry and a
cap on relay fees. The owner can pause, rotate the agent's key, withdraw, or revoke and take back
the unspent balance at any time. Nobody else can move a mandate's funds.

Version 2 keeps every rail and the kill switch of v1 and adds what agents need on chains other than
CreditChain and at production volume: any asset, signed spends that anyone can relay, payment
receipts, agent key rotation and pause.

## Motivation

An AI agent that pays for inference, data and API calls thousands of times an hour cannot ask a
person to approve each payment, and must not hold a key that controls everything. What it needs is
*bounded authority*: "spend up to X in total, at most Y per payment, no faster than Z a day, only to
these recipients, until this date, and I can stop you at any moment."

v1 delivered that in CreditChain's native coin. Agents on Base, Ethereum and every other EVM chain
price their work in stablecoins, often cannot hold gas, and need their payments to say what they
paid for. v2 is the same promise, everywhere.

## Specification

The key words "MUST", "MUST NOT", "SHOULD" and "MAY" are as in RFC 2119 and RFC 8174.

A compliant contract MUST implement `IAgentMandateVault`
([source](../src/agm/IAgentMandateVault.sol)) and ERC-165, returning `true` for its interface id.

### Assets

`asset == address(0)` is the native coin; any other value is an ERC-20. A mandate holds exactly one
asset for its whole life. On funding, an implementation MUST credit the amount it actually received
(so fee-on-transfer tokens are handled) and MUST treat a call to an address without code as a
failure. It MUST handle ERC-20s that return no value. Tokens whose balances change without a
transfer (rebasing) are out of scope.

### Rails

For a spend of `amount` with relay fee `fee` (zero for a direct spend), an implementation MUST revert,
moving nothing, unless all of the following hold:

| Rail | Condition | Zero means |
|---|---|---|
| not revoked, not paused | `!revoked && !paused` | — |
| expiry | `expiry == 0 \|\| now <= expiry` | never expires |
| allowlist | `!allowlistEnabled \|\| allowlisted(recipient)` | — |
| per payment | `perTxMax == 0 \|\| amount <= perTxMax` | no cap |
| budget | `budget == 0 \|\| spent + amount + fee <= budget` | no cap |
| balance | `amount + fee <= balance` | — |
| window | `windowLimit == 0 \|\| windowSpent' + amount + fee <= windowLimit` | no window |
| relay fee | `fee <= maxRelayFee` | relays must be free |

`windowSpent'` is zero once `windowSeconds` have passed since `windowStart`, in which case the window
restarts at `now`. Relay fees count against the budget, the window and the balance exactly like
payments, so the owner's worst case is `min(budget, balance)` whatever the agent signs and
whoever relays it.

### Signed spends

The agent MAY sign an EIP-712 `SpendAuthorization` and anyone MAY submit it with
`spendWithSignature`; the submitter receives `fee`. The domain is
`{ name: "ERC-AGM AgentMandateVault", version: "2", chainId, verifyingContract }`, recomputed on every
call. The type is:

```
SpendAuthorization(uint256 mandateId,address recipient,uint256 amount,bytes32 receipt,
                   uint256 fee,uint256 nonce,uint256 deadline)
```

An implementation MUST accept a signature when it is a canonical (low-s) ECDSA signature by the
agent, or when the agent is a contract whose ERC-1271 `isValidSignature` returns the magic value. It
MUST try ECDSA first, so that an EIP-7702-delegated agent's own key keeps working. Nonces are
unordered: each value works once per mandate. A signature MUST be rejected after `deadline`, after
its nonce is used, and once the owner has rotated the agent to another key.

### Receipts

Every payment carries a 32-byte `receipt` (named `taskRef` in the event, for v1 compatibility). It
SHOULD be `keccak256` of a receipt document describing what was paid for. A RECOMMENDED document:

```json
{ "type": "erc-agm-receipt/1", "mandate": "eip155:<chainId>:<vault>/<mandateId>",
  "request": { "method": "POST", "url": "https://api.example/v1/infer", "bodyHash": "0x…" },
  "service": { "agentRegistry": "eip155:1:0x8004…", "agentId": 22 },
  "quote": { "amount": "1200", "asset": "0x…" }, "createdAt": "2026-10-20T12:00:00Z" }
```

The chain stores only the hash; the parties keep the document. It is how an owner, an auditor or a
dispute process later checks what each payment bought.

### Events

`AgentPayment`, `MandateRevoked` and `Withdrawn` keep their v1 signatures, so indexers of v1
payments read v2 payments unchanged. v2 adds `RelayFeePaid`, `AgentRotated` and `MandatePaused`, and
`MandateCreated` gains `asset` and `maxRelayFee`.

### Self-payment

`spentToOwner` records payments whose recipient is the mandate's own owner. Anything that builds
reputation from mandates SHOULD exclude it: paying yourself through your own agent is not work.

## Rationale

- **One asset per mandate** keeps every rail a single number. An owner who wants an agent to spend
  two assets grants two mandates.
- **Fees inside the budget** is what makes "the agent never needs gas" safe: the relayer is paid,
  and the owner's ceiling does not move.
- **Unordered nonces** let an agent sign many payments at once without coordinating a counter.
- **uint128 storage.** The reference implementation packs a mandate into seven slots; 3.4 × 10³⁸
  units exceeds any real token supply, and larger values revert instead of truncating.
- **Same address everywhere.** The reference implementation is created by the
  deterministic-deployment proxy with a fixed salt, so agents and SDKs find it at one address on
  every chain.

## Backwards compatibility

v1 mandates keep working in their own contracts. v2 is a separate contract and interface;
events shared with v1 have identical signatures.

## Reference implementation

[`AgentMandateVault.sol`](../src/agm/AgentMandateVault.sol): 46 unit and fuzz tests, plus invariant
tests (solvency per asset, conservation of value, every rail) over random sequences of creates,
funding, direct and relayed spends, withdrawals, revocations, pauses and key rotations across the
native coin, a plain ERC-20 and a fee-on-transfer ERC-20.

## Security considerations

- **Not audited.** Do not hold value you cannot afford to lose in it until it has been.
- A relayer chooses only *when* a signed payment lands, never its recipient, amount or receipt.
- A revoked mandate rejects new funding: its agent can never spend again.
- Recipients that revert make the whole payment revert; nothing is lost and nothing moves.
- An owner whose address cannot receive the native coin cannot withdraw native funds; choose an
  owner that can.

## Copyright

Copyright and related rights waived via CC0. The reference implementation is MIT OR Apache-2.0.
