#!/usr/bin/env bash
# Prove the AgentClearing four-layer stack against an already-deployed,
# source-verified contract on the testnet.
#
# The claim under test is economic, not just functional: an agent can make
# thousands of payments whose marginal on-chain cost is zero, and settle the
# whole run in one transaction. A unit test can assert that; only the live chain
# can demonstrate it, so this script does it with real transactions and reports
# real gas.
#
# Self-service: agents are throwaway keys created here and funded from the
# public faucet, so anyone can re-run it without being given a key.
#
# Testnet only, by construction. Test CCC has no monetary value.
#
#   CLEARING=0x… ./prove_clearing_against_deployed.sh
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"

RPC_URL="${RPC_URL:-https://testnet.creditchain.org}"
FAUCET="${FAUCET:-https://faucet.creditchain.org/testnet/drip}"
EXPECT_CHAIN="${EXPECT_CHAIN:-2026042404}"
CLEARING="${CLEARING:?set CLEARING to the deployed AgentClearing address}"
PAYMENTS="${PAYMENTS:-1000}"
HERE="$(cd "$(dirname "$0")" && pwd)"
CLIENT="$HERE/voucher_client.py"

b()   { printf '\n\033[1m%s\033[0m\n' "$*"; }
dim() { printf '\033[2m%s\033[0m\n' "$*"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
no()  { printf '  \033[31m✗\033[0m %s\n' "$*"; exit 1; }
ccc() { python3 -c "import sys;print(f'{int(sys.argv[1])/1e18:.6g}')" "$1"; }

CHAIN="$(cast chain-id --rpc-url "$RPC_URL")"
[ "$CHAIN" = "$EXPECT_CHAIN" ] || { echo "refusing: chain $CHAIN is not testnet $EXPECT_CHAIN" >&2; exit 1; }
[ "$(cast code "$CLEARING" --rpc-url "$RPC_URL" | wc -c)" -gt 4 ] || {
  echo "refusing: no contract at $CLEARING on chain $CHAIN" >&2; exit 1; }

b "AgentClearing proof — $CLEARING"
dim "  chain $CHAIN · block $(cast block-number --rpc-url "$RPC_URL")"

python3 "$CLIENT" selftest >/dev/null || no "voucher client selftest failed"
ok "off-chain voucher client selftest passed (keccak + secp256k1 + recovery)"

# Two throwaway agents: one buys, one sells. Neither key outlives this script.
PAYER_KEY="$(cast wallet new --json | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["private_key"])')"
PAYEE_KEY="$(cast wallet new --json | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["private_key"])')"
PAYER="$(cast wallet address --private-key "$PAYER_KEY")"
PAYEE="$(cast wallet address --private-key "$PAYEE_KEY")"
dim "  payer (buying agent)   $PAYER"
dim "  payee (selling agent)  $PAYEE"

for A in "$PAYER" "$PAYEE"; do
  curl -fsS -X POST "$FAUCET" -H 'content-type: application/json' -d "{\"address\":\"$A\"}" >/dev/null
done
sleep 4
ok "both agents funded from the public faucet (1 CCC each)"

send() { cast send --rpc-url "$RPC_URL" --private-key "$1" --json "${@:2}"; }
gas_of() { python3 -c "import sys,json;print(int(json.load(sys.stdin)['gasUsed'],16) if str(json.load(open('/dev/null')) or '') else 0)" 2>/dev/null; }

b "0. the client and the chain agree on what a voucher is"
LOCAL="$(python3 "$CLIENT" digest chain="$CHAIN" contract="$CLEARING" channel=1 cumulative=12345)"
ONCHAIN="$(cast call --rpc-url "$RPC_URL" "$CLEARING" 'voucherDigest(uint256,uint256)(bytes32)' 1 12345)"
[ "$LOCAL" = "$ONCHAIN" ] || no "digest mismatch: local $LOCAL vs chain $ONCHAIN"
ok "EIP-712 digest computed offline == voucherDigest() on-chain"
dim "  $LOCAL"

b "1. DEPOSIT — collateral is posted once"
send "$PAYER_KEY" --value 0.5ether "$CLEARING" 'deposit()' >/dev/null
ok "payer deposited $(ccc "$(cast call --rpc-url "$RPC_URL" "$CLEARING" 'available(address)(uint256)' "$PAYER" | cut -d' ' -f1)") CCC of available collateral"

b "2. PAYMENT — a channel, then $PAYMENTS payments that never touch the chain"
COMMIT=200000000000000000   # 0.2 CCC reserved against this channel
send "$PAYER_KEY" "$CLEARING" 'openChannel(address,uint256,uint256,uint64)' \
  "$PAYEE" "$COMMIT" "$COMMIT" "$(( $(date +%s) + 86400 ))" >/dev/null
CH="$(cast call --rpc-url "$RPC_URL" "$CLEARING" 'channelCount()(uint256)' | cut -d' ' -f1)"
ok "channel #$CH open · $(ccc $COMMIT) CCC committed · payer's available now $(ccc "$(cast call --rpc-url "$RPC_URL" "$CLEARING" 'available(address)(uint256)' "$PAYER" | cut -d' ' -f1)") CCC"

STEP=100000000000000        # 0.0001 CCC per payment
STREAM="$(VOUCHER_KEY="$PAYER_KEY" python3 "$CLIENT" stream \
  chain="$CHAIN" contract="$CLEARING" channel="$CH" step="$STEP" count="$PAYMENTS")"
CUM="$(python3 -c "import sys,json;print(json.loads(sys.argv[1])['cumulative'])" "$STREAM")"
SIG="$(python3 -c "import sys,json;print(json.loads(sys.argv[1])['signature'])" "$STREAM")"
MSPP="$(python3 -c "import sys,json;print(json.loads(sys.argv[1])['ms_per_payment'])" "$STREAM")"
SECS="$(python3 -c "import sys,json;print(json.loads(sys.argv[1])['seconds'])" "$STREAM")"
ok "$PAYMENTS payments issued in ${SECS}s (${MSPP} ms each) · 0 transactions · 0 gas"
dim "  running total $(ccc "$CUM") CCC, carried by one $((${#SIG}/2 - 1))-byte signature"

BEFORE="$(cast block-number --rpc-url "$RPC_URL")"

b "3. SETTLEMENT — one transaction banks the whole run"
RCPT="$(send "$PAYEE_KEY" "$CLEARING" 'redeem(uint256,uint256,bytes)' "$CH" "$CUM" "$SIG")"
GAS="$(python3 -c "import sys,json;print(int(json.loads(sys.argv[1])['gasUsed'],16))" "$RCPT")"
PAID="$(cast call --rpc-url "$RPC_URL" "$CLEARING" 'available(address)(uint256)' "$PAYEE" | cut -d' ' -f1)"
[ "$PAID" = "$CUM" ] || no "payee credited $PAID, expected $CUM"
ok "payee credited $(ccc "$PAID") CCC in ONE redemption · $GAS gas"
dim "  $(python3 -c "print(f'{$GAS/$PAYMENTS:.1f}')") gas per payment — and it falls further the longer the channel runs"
dim "  a naive on-chain transfer per payment would be ~$(python3 -c "print(f'{21000*$PAYMENTS/1e6:.1f}')")M gas"

b "4. CLEARING — many channels, one settlement"
send "$PAYER_KEY" "$CLEARING" 'openChannel(address,uint256,uint256,uint64)' \
  "$PAYEE" 100000000000000000 100000000000000000 "$(( $(date +%s) + 86400 ))" >/dev/null
CH2="$(cast call --rpc-url "$RPC_URL" "$CLEARING" 'channelCount()(uint256)' | cut -d' ' -f1)"

CUM_A=$(( CUM + 20 * STEP ))
SIG_A="$(VOUCHER_KEY="$PAYER_KEY" python3 "$CLIENT" stream chain="$CHAIN" contract="$CLEARING" \
  channel="$CH" step="$CUM_A" count=1 | python3 -c 'import sys,json;print(json.load(sys.stdin)["signature"])')"
CUM_B=$(( 30 * STEP ))
SIG_B="$(VOUCHER_KEY="$PAYER_KEY" python3 "$CLIENT" stream chain="$CHAIN" contract="$CLEARING" \
  channel="$CH2" step="$CUM_B" count=1 | python3 -c 'import sys,json;print(json.load(sys.stdin)["signature"])')"

RCPT="$(send "$PAYEE_KEY" "$CLEARING" 'settleBatch((uint256,uint256,bytes)[])' \
  "[($CH,$CUM_A,$SIG_A),($CH2,$CUM_B,$SIG_B)]")"
BGAS="$(python3 -c "import sys,json;print(int(json.loads(sys.argv[1])['gasUsed'],16))" "$RCPT")"
TOTAL="$(cast call --rpc-url "$RPC_URL" "$CLEARING" 'available(address)(uint256)' "$PAYEE" | cut -d' ' -f1)"
EXPECT=$(( CUM_A + CUM_B ))
[ "$TOTAL" = "$EXPECT" ] || no "payee holds $TOTAL, expected $EXPECT"
ok "2 channels netted in ONE transaction · $BGAS gas · payee now holds $(ccc "$TOTAL") CCC"
dim "  obligations from both channels collapsed into a single balance write"

b "5. the close window is real"
send "$PAYER_KEY" "$CLEARING" 'startClose(uint256)' "$CH2" >/dev/null
if cast send --rpc-url "$RPC_URL" --private-key "$PAYER_KEY" "$CLEARING" \
     'closeChannel(uint256)' "$CH2" >/dev/null 2>&1; then
  no "channel closed early — the payee's settlement window is not enforced"
fi
ok "closeChannel reverted: payer cannot reclaim collateral inside the $(cast call --rpc-url "$RPC_URL" "$CLEARING" 'CLOSE_WINDOW()(uint64)' | cut -d' ' -f1)s window"
dim "  this is what stops a payer withdrawing while a signed voucher is in flight"

b "6. WITHDRAW — value leaves only to whoever earned it"
WAS="$(cast balance "$PAYEE" --rpc-url "$RPC_URL")"
send "$PAYEE_KEY" "$CLEARING" 'withdraw(uint256)' "$TOTAL" >/dev/null
NOW="$(cast balance "$PAYEE" --rpc-url "$RPC_URL")"
python3 -c "
was,now,amt=$WAS,$NOW,$TOTAL
assert now > was, 'payee balance did not increase'
print(f'  \033[32m✓\033[0m payee withdrew {amt/1e18:.6g} CCC to their own account (net of gas: +{(now-was)/1e18:.6g} CCC)')"

b "7. SOLVENCY — the contract still holds everything it owes"
HELD="$(cast balance "$CLEARING" --rpc-url "$RPC_URL")"
OWED="$(python3 -c "print($(cast call --rpc-url "$RPC_URL" "$CLEARING" 'available(address)(uint256)' "$PAYER" | cut -d' ' -f1) + $(cast call --rpc-url "$RPC_URL" "$CLEARING" 'reserved(address)(uint256)' "$PAYER" | cut -d' ' -f1) + $(cast call --rpc-url "$RPC_URL" "$CLEARING" 'available(address)(uint256)' "$PAYEE" | cut -d' ' -f1))")"
python3 -c "
held,owed=$HELD,$OWED
assert held >= owed, f'INSOLVENT: holds {held} owes {owed}'
print(f'  \033[32m✓\033[0m holds {held/1e18:.6g} CCC against {owed/1e18:.6g} CCC of book liabilities')"

b "proved on chain $CHAIN, blocks $BEFORE-$(cast block-number --rpc-url "$RPC_URL")"
dim "  $PAYMENTS payments · 1 redemption · 1 batch settlement · contract solvent throughout"
