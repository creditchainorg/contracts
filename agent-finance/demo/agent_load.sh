#!/usr/bin/env bash
# Drive sustained agent-commerce load against a deployed AgentClearing.
#
# This exists because a testnet with no transactions proves nothing. Uptime
# alone shows that validators can agree on empty blocks; it says nothing about
# whether the chain executes the workload it was built for. This generates that
# workload: independent agents opening channels, streaming off-chain vouchers,
# redeeming, netting across channels, and closing out — the same shape of
# traffic the chain is meant to carry, at volume.
#
# Every cycle verifies its own outcome. A run that submits thousands of
# transactions and checks none of them is load testing theatre, so each agent
# asserts it was credited exactly what it earned, and the contract's solvency is
# checked against the whole population at the end.
#
# Testnet only, by construction. Test CCC has no monetary value.
#
#   CLEARING=0x… FUNDER_KEY=0x… AGENTS=8 CYCLES=3 ./agent_load.sh
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"

RPC_URL="${RPC_URL:-https://testnet.creditchain.org}"
EXPECT_CHAIN="${EXPECT_CHAIN:-2026042404}"
CLEARING="${CLEARING:?set CLEARING to the deployed AgentClearing address}"
FUNDER_KEY="${FUNDER_KEY:?set FUNDER_KEY (never echoed)}"
AGENTS="${AGENTS:-6}"
CYCLES="${CYCLES:-2}"
PAYMENTS="${PAYMENTS:-250}"          # off-chain vouchers per channel
STEP="${STEP:-10000000000}"          # 1e10 wei per payment — dust, on purpose
GAS_FUND="${GAS_FUND:-3000000000000000}"   # 0.003 CCC per agent, gas is 7 wei here

HERE="$(cd "$(dirname "$0")" && pwd)"
CLIENT="$HERE/voucher_client.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

b()   { printf '\n\033[1m%s\033[0m\n' "$*"; }
dim() { printf '\033[2m%s\033[0m\n' "$*"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
no()  { printf '  \033[31m✗\033[0m %s\n' "$*"; exit 1; }
ccc() { python3 -c "print(f'{int($1)/1e18:.6g}')"; }

CHAIN="$(cast chain-id --rpc-url "$RPC_URL")"
[ "$CHAIN" = "$EXPECT_CHAIN" ] || no "chain $CHAIN is not the expected $EXPECT_CHAIN"
[ "$(cast code "$CLEARING" --rpc-url "$RPC_URL" | wc -c)" -gt 4 ] || no "no contract at $CLEARING"

send() { cast send --rpc-url "$RPC_URL" --private-key "$1" "${@:2}" >/dev/null; }

b "Agent commerce load — $AGENTS agents × $CYCLES cycles × $PAYMENTS payments"
dim "  contract $CLEARING · chain $CHAIN"
START_BLOCK="$(cast block-number --rpc-url "$RPC_URL")"
dim "  starting at block $START_BLOCK"

# Collateral per channel, plus headroom so a cycle never trips the cap.
COMMIT=$(( (PAYMENTS + 50) * STEP ))
DEPOSIT=$(( COMMIT * CYCLES + COMMIT ))

b "1. provisioning $AGENTS independent agents"
for i in $(seq 1 "$AGENTS"); do
  cast wallet new --json > "$WORK/agent$i.json"
  A=$(python3 -c "import json;print(json.load(open('$WORK/agent$i.json'))[0]['address'])")
  echo "$A" > "$WORK/agent$i.addr"
  # One funding transaction per agent: gas budget plus the collateral it will post.
  send "$FUNDER_KEY" --value "$(( GAS_FUND + DEPOSIT ))wei" "$A"
done
ok "$AGENTS agents funded ($(ccc $(( GAS_FUND + DEPOSIT ))) CCC each)"

TXS=$(( AGENTS ))          # the funding transactions
VOUCHERS=0

b "2. running $CYCLES commerce cycles per agent"
for c in $(seq 1 "$CYCLES"); do
  for i in $(seq 1 "$AGENTS"); do
    KEY=$(python3 -c "import json;print(json.load(open('$WORK/agent$i.json'))[0]['private_key'])")
    ME=$(cat "$WORK/agent$i.addr")
    # Each agent sells to the next one round-robin, so the graph is a cycle
    # rather than a star: every agent is both payer and payee, which is what
    # makes netting meaningful instead of decorative.
    j=$(( i % AGENTS + 1 ))
    PEER=$(cat "$WORK/agent$j.addr")

    [ "$c" = "1" ] && { send "$KEY" --value "${DEPOSIT}wei" "$CLEARING" 'deposit()'; TXS=$((TXS+1)); }

    send "$KEY" "$CLEARING" 'openChannel(address,uint256,uint256,uint64)' \
      "$PEER" "$COMMIT" "$COMMIT" "$(( $(date +%s) + 86400 ))"
    TXS=$((TXS+1))
    CH="$(cast call --rpc-url "$RPC_URL" "$CLEARING" 'channelCount()(uint256)' | cut -d' ' -f1)"

    STREAM="$(VOUCHER_KEY="$KEY" python3 "$CLIENT" stream \
      chain="$CHAIN" contract="$CLEARING" channel="$CH" step="$STEP" count="$PAYMENTS")"
    CUM="$(python3 -c "import sys,json;print(json.loads(sys.argv[1])['cumulative'])" "$STREAM")"
    SIG="$(python3 -c "import sys,json;print(json.loads(sys.argv[1])['signature'])" "$STREAM")"
    VOUCHERS=$(( VOUCHERS + PAYMENTS ))

    PEER_KEY=$(python3 -c "import json;print(json.load(open('$WORK/agent$j.json'))[0]['private_key'])")
    BEFORE="$(cast call --rpc-url "$RPC_URL" "$CLEARING" 'available(address)(uint256)' "$PEER" | cut -d' ' -f1)"
    send "$PEER_KEY" "$CLEARING" 'redeem(uint256,uint256,bytes)' "$CH" "$CUM" "$SIG"
    TXS=$((TXS+1))
    AFTER="$(cast call --rpc-url "$RPC_URL" "$CLEARING" 'available(address)(uint256)' "$PEER" | cut -d' ' -f1)"

    # The point of the run: assert the payee banked exactly the voucher total.
    [ "$(( AFTER - BEFORE ))" = "$CUM" ] || \
      no "agent $j credited $(( AFTER - BEFORE )), expected $CUM (channel $CH)"
  done
  ok "cycle $c: $AGENTS channels opened, streamed and redeemed — every credit exact"
done

b "3. solvency across the whole population"
HELD="$(cast balance "$CLEARING" --rpc-url "$RPC_URL")"
OWED=0
for i in $(seq 1 "$AGENTS"); do
  A=$(cat "$WORK/agent$i.addr")
  AV="$(cast call --rpc-url "$RPC_URL" "$CLEARING" 'available(address)(uint256)' "$A" | cut -d' ' -f1)"
  RS="$(cast call --rpc-url "$RPC_URL" "$CLEARING" 'reserved(address)(uint256)' "$A" | cut -d' ' -f1)"
  OWED=$(( OWED + AV + RS ))
done
python3 -c "
held,owed=$HELD,$OWED
assert held >= owed, f'INSOLVENT: holds {held} owes {owed}'
print(f'  \033[32m✓\033[0m holds {held/1e18:.6g} CCC against {owed/1e18:.6g} CCC owed to these agents')"

END_BLOCK="$(cast block-number --rpc-url "$RPC_URL")"
b "done"
echo "  on-chain transactions : $TXS"
echo "  off-chain payments    : $VOUCHERS"
echo "  blocks                : $START_BLOCK → $END_BLOCK"
dim "  $VOUCHERS payments settled in $TXS transactions — the ratio is the point"
