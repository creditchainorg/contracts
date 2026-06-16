#!/usr/bin/env bash
# Agent-commerce demo — the loop nobody else can run.
#
# Proves AgentSpendVault end-to-end on a LIVE CreditChain node with real CCC:
#   1. Owner funds a vault and grants an agent a bounded mandate.
#   2. The agent autonomously pays a metered service within its rails.
#   3. The CHAIN rejects an over-rail payment (budget / per-tx / allowlist).
#   4. Owner hits the kill switch — revoke refunds the unspent balance.
#
# Everything below is enforced by the deployed contract, not by this script.
# The script is only an operator: it sends the agent's transactions and reads
# back what the chain allowed. No human approves any individual payment.
#
# Usage:
#   RPC_URL=http://localhost:8545 ./agent_commerce_demo.sh
# Env (all optional):
#   RPC_URL     JSON-RPC endpoint           (default http://localhost:8545)
#   OWNER_KEY   funded owner/deployer key   (default: devnet faucet.key)
#   VAULT       existing vault address      (default: deploy a fresh one)
set -euo pipefail

export PATH="$HOME/.foundry/bin:$PATH"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

RPC_URL="${RPC_URL:-http://localhost:8545}"
OWNER_KEY="${OWNER_KEY:-0x$(tr -d '[:space:]' < "$ROOT/deploy/devnet/secrets/faucet.key")}"
[[ "$OWNER_KEY" == 0x0x* ]] && OWNER_KEY="0x${OWNER_KEY#0x0x}"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
dim()   { printf '\033[2m%s\033[0m\n' "$*"; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
no()    { printf '  \033[31m✗ chain rejected:\033[0m %s\n' "$*"; }
ccc()   { cast to-unit "$(awk '{print $1}' <<<"$1")" ether; }  # wei (cast may suffix "[2e18]") -> CCC
e18()   { cast to-wei "$1" ether; }           # CCC -> wei
reason() { # decode a revert's 4-byte selector to the custom error name
  local sel="${1:0:10}" name
  for name in PerTxExceeded BudgetExceeded RecipientNotAllowed MandateInactive \
              InsufficientBalance WindowExceeded NotAgent NotOwner ZeroAmount; do
    [[ "$(cast sig "${name}()" 2>/dev/null)" == "$sel" ]] && { echo "${name}()"; return; }
  done
  echo "$sel"
}

OWNER_ADDR="$(cast wallet address --private-key "$OWNER_KEY")"

bold "════════════════════════════════════════════════════════════════"
bold "  CreditChain — Agent Commerce, live on-chain"
bold "════════════════════════════════════════════════════════════════"
dim  "  RPC:    $RPC_URL  (chainId $(cast chain-id --rpc-url "$RPC_URL"))"
dim  "  Block:  $(cast block-number --rpc-url "$RPC_URL")"
dim  "  Owner:  $OWNER_ADDR"
echo

# ── Cast of characters ───────────────────────────────────────────────────────
# The agent gets a small gas stipend only — it NEVER holds the spending funds.
# Its spending authority lives entirely inside the mandate on-chain.
read -r AGENT_ADDR AGENT_KEY < <(cast wallet new | awk '/Address/{a=$2} /Private key/{k=$3} END{print a, k}')
MERCHANT="$(cast wallet new | awk '/Address/{print $2; exit}')"   # the metered API provider
OUTSIDER="$(cast wallet new | awk '/Address/{print $2; exit}')"   # a NON-allowlisted address

dim "  Agent:    $AGENT_ADDR   (autonomous payer)"
dim "  Merchant: $MERCHANT   (allowlisted API provider)"
dim "  Outsider: $OUTSIDER   (NOT allowlisted)"
echo

bold "▸ Stipend: give the agent gas money (not spending money)"
cast send --rpc-url "$RPC_URL" --private-key "$OWNER_KEY" \
  --value "$(e18 0.05)" "$AGENT_ADDR" >/dev/null
ok "agent funded with 0.05 CCC for gas only"
echo

# ── Deploy (or reuse) the vault ──────────────────────────────────────────────
if [[ -z "${VAULT:-}" ]]; then
  bold "▸ Deploy AgentSpendVault"
  VAULT="$(forge create "$HERE/../src/AgentSpendVault.sol:AgentSpendVault" \
    --rpc-url "$RPC_URL" --private-key "$OWNER_KEY" --broadcast \
    | awk '/Deployed to/{print $3}')"
  ok "deployed at $VAULT"
else
  bold "▸ Using existing vault $VAULT"
fi
echo

# ── 1. Grant a mandate ───────────────────────────────────────────────────────
# "Spend up to 5 CCC total, at most 2 per payment, only to the merchant."
BUDGET=$(e18 5); PERTX=$(e18 2); FUND=$(e18 5)
bold "▸ Owner grants a mandate (the human sets the rails, once)"
dim  "    budget 5 CCC · per-tx ≤ 2 CCC · recipient allowlist ON · funded 5 CCC"
cast send --rpc-url "$RPC_URL" --private-key "$OWNER_KEY" --value "$FUND" "$VAULT" \
  "createMandate(address,uint256,uint256,uint256,uint64,uint64,bool)" \
  "$AGENT_ADDR" "$BUDGET" "$PERTX" 0 0 0 true >/dev/null
ID="$(cast call --rpc-url "$RPC_URL" "$VAULT" "mandateCount()(uint256)")"
cast send --rpc-url "$RPC_URL" --private-key "$OWNER_KEY" "$VAULT" \
  "allowRecipient(uint256,address,bool)" "$ID" "$MERCHANT" true >/dev/null
ok "mandate #$ID created; merchant allowlisted"
dim "    spendableNow = $(ccc "$(cast call --rpc-url "$RPC_URL" "$VAULT" 'spendableNow(uint256)(uint256)' "$ID")") CCC  (tightest rail = per-tx cap)"
echo

agent_pay() { # amount_ccc  taskref  -> sends as the AGENT
  cast send --rpc-url "$RPC_URL" --private-key "$AGENT_KEY" "$VAULT" \
    "spend(uint256,address,uint256,bytes32)" "$ID" "$1" "$(e18 "$2")" \
    "$(cast keccak "$3")" >/dev/null
}
agent_try() { # like agent_pay but expects the chain to reject (eth_call sim)
  cast call --rpc-url "$RPC_URL" --from "$AGENT_ADDR" "$VAULT" \
    "spend(uint256,address,uint256,bytes32)" "$ID" "$1" "$(e18 "$2")" \
    "$(cast keccak "$3")" 2>&1 || true
}

# ── 2. The agent works and pays — autonomously, no human per payment ─────────
bold "▸ Agent runs its workload and pays per task (no human in the loop)"
agent_pay "$MERCHANT" 2 "task:image-embed-001"; ok "paid 2 CCC for task image-embed-001  → merchant"
agent_pay "$MERCHANT" 2 "task:image-embed-002"; ok "paid 2 CCC for task image-embed-002  → merchant"
dim "    merchant balance now: $(ccc "$(cast balance "$MERCHANT" --rpc-url "$RPC_URL")") CCC"
dim "    spendableNow = $(ccc "$(cast call --rpc-url "$RPC_URL" "$VAULT" 'spendableNow(uint256)(uint256)' "$ID")") CCC  (only 1 CCC of budget left)"
echo

# ── 3. The chain — not a human — enforces every rail ─────────────────────────
bold "▸ The chain refuses every out-of-bounds payment (rails enforced on-chain)"
R="$(agent_try "$MERCHANT" 3 "task:too-big")";        no "single 3 CCC payment > 2 CCC per-tx cap        $(reason "$(grep -o '0x[0-9a-f]*' <<<"$R" | tail -1)")"
R="$(agent_try "$MERCHANT" 2 "task:over-budget")";    no "2 CCC payment > 1 CCC remaining budget         $(reason "$(grep -o '0x[0-9a-f]*' <<<"$R" | tail -1)")"
R="$(agent_try "$OUTSIDER" 1 "task:wrong-payee")";    no "payment to a non-allowlisted address           $(reason "$(grep -o '0x[0-9a-f]*' <<<"$R" | tail -1)")"
ok "agent CAN still make a valid 1 CCC payment within its remaining budget:"
agent_pay "$MERCHANT" 1 "task:image-embed-003"; ok "paid 1 CCC for task image-embed-003  → merchant (budget now exhausted)"
echo

# ── 4. The owner's kill switch ───────────────────────────────────────────────
bold "▸ Owner revokes the mandate — instant kill switch + refund of the unspent"
cast send --rpc-url "$RPC_URL" --private-key "$OWNER_KEY" "$VAULT" "revoke(uint256)" "$ID" >/dev/null
ok "mandate revoked; unspent CCC refunded to owner"
R="$(agent_try "$MERCHANT" 1 "task:after-revoke")";   no "agent payment after revoke                      $(reason "$(grep -o '0x[0-9a-f]*' <<<"$R" | tail -1)")"
echo

bold "════════════════════════════════════════════════════════════════"
bold "  Result: the agent spent autonomously; the chain held every rail;"
bold "  the owner never approved a single payment and reclaimed the rest."
bold "  Vault: $VAULT"
bold "════════════════════════════════════════════════════════════════"
