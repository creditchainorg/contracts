#!/usr/bin/env bash
# Re-create the public mandate proof against an ALREADY-DEPLOYED, source-verified
# AgentSpendVault, rather than deploying a throwaway one.
#
# agent_commerce_demo.sh deploys a fresh vault each run, which is right for a
# local walkthrough but wrong for the public proof: forge.creditchain.org reads
# mandates from one specific verified address, so the evidence has to live there.
# When a network is re-genesised the contracts are redeployed and that page ends
# up pointing at an address with no history -- this script repopulates it.
#
# Testnet only, by construction: it refuses any chain id other than the testnet's.
# Test CCC has no monetary value.
#
#   VAULT=0x… OWNER_KEY=0x… ./prove_against_deployed.sh
set -euo pipefail

RPC_URL="${RPC_URL:-https://testnet.creditchain.org}"
EXPECT_CHAIN="${EXPECT_CHAIN:-2026042404}"
VAULT="${VAULT:?set VAULT to the deployed AgentSpendVault address}"
OWNER_KEY="${OWNER_KEY:?set OWNER_KEY (never echo it)}"

b()   { printf '\033[1m%s\033[0m\n' "$*"; }
dim() { printf '\033[2m%s\033[0m\n' "$*"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
no()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
ccc() { python3 -c "import sys;print(f'{int(sys.argv[1])/1e18:g}')" "$1"; }

CHAIN="$(cast chain-id --rpc-url "$RPC_URL")"
if [ "$CHAIN" != "$EXPECT_CHAIN" ]; then
  echo "refusing to run: chain id $CHAIN is not the expected testnet $EXPECT_CHAIN" >&2
  exit 1
fi
[ "$(cast code "$VAULT" --rpc-url "$RPC_URL" | wc -c)" -gt 4 ] || {
  echo "refusing to run: no contract at $VAULT on chain $CHAIN" >&2; exit 1; }

b "AgentSpendVault proof — $VAULT"
dim "  chain $CHAIN · block $(cast block-number --rpc-url "$RPC_URL")"

# Throwaway agent + merchant. The agent key is created here and never reused:
# it exists only to show that an agent spends without the owner's key.
AGENT_KEY="$(cast wallet new --json | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["private_key"])')"
AGENT="$(cast wallet address --private-key "$AGENT_KEY")"
MERCHANT="$(cast wallet address --private-key "$(cast wallet new --json | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["private_key"])')")"
dim "  agent    $AGENT  (throwaway)"
dim "  merchant $MERCHANT"

send() { cast send --rpc-url "$RPC_URL" --private-key "$1" "${@:2}" >/dev/null; }

b "1. owner grants a bounded mandate — the one human decision"
send "$OWNER_KEY" --value 3ether "$VAULT" \
  'createMandate(address,uint256,uint256,uint256,uint64,uint64,bool)' \
  "$AGENT" 3000000000000000000 1000000000000000000 0 0 0 false
ID="$(cast call --rpc-url "$RPC_URL" "$VAULT" 'mandateCount()(uint256)')"
ok "mandate #$ID · budget 3 CCC · per-tx <= 1 CCC"

# The agent needs gas, not authority: this is the only thing the owner gives it
# besides the mandate itself.
send "$OWNER_KEY" --value 0.05ether "$AGENT"
dim "  funded agent with 0.05 CCC for gas (authority comes from the mandate, not the balance)"

b "2. agent spends autonomously — no human approves any payment"
send "$AGENT_KEY" "$VAULT" 'spend(uint256,address,uint256,bytes32)' \
  "$ID" "$MERCHANT" 1000000000000000000 "$(cast keccak 'task-1')"
ok "paid 1 CCC for task 1 -> merchant"
send "$AGENT_KEY" "$VAULT" 'spend(uint256,address,uint256,bytes32)' \
  "$ID" "$MERCHANT" 1000000000000000000 "$(cast keccak 'task-2')"
ok "paid 1 CCC for task 2 -> merchant"

b "3. the chain refuses what the mandate does not allow"
if send "$AGENT_KEY" "$VAULT" 'spend(uint256,address,uint256,bytes32)' \
     "$ID" "$MERCHANT" 2000000000000000000 "$(cast keccak 'task-3')" 2>/dev/null; then
  no "OVER-CAP SPEND SUCCEEDED — this is a failure of the proof"; exit 1
else
  no "chain rejected: 2 CCC > 1 CCC per-tx cap -> PerTxExceeded()"
fi

b "4. owner revokes — the agent is instantly powerless"
send "$OWNER_KEY" "$VAULT" 'revoke(uint256)' "$ID"
ok "mandate #$ID revoked; unspent balance refunded to the owner"
if send "$AGENT_KEY" "$VAULT" 'spend(uint256,address,uint256,bytes32)' \
     "$ID" "$MERCHANT" 100000000000000000 "$(cast keccak 'task-4')" 2>/dev/null; then
  no "SPEND AFTER REVOKE SUCCEEDED — this is a failure of the proof"; exit 1
else
  no "chain rejected: any spend after revoke -> MandateInactive()"
fi

b "done — mandate #$ID is now readable on-chain"
dim "  cast call $VAULT 'mandate(uint256)' $ID --rpc-url $RPC_URL"
dim "  merchant balance: $(ccc "$(cast balance "$MERCHANT" --rpc-url "$RPC_URL")") CCC"
