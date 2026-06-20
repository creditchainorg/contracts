#!/usr/bin/env bash
# Verify a deployed contract on the CreditChain explorer — self-serve, via the
# public API. Compiles the local source with the project's pinned settings and
# submits {source, ABI, compiled deployedBytecode, compiler settings} to
#   POST /v1/contracts/:address/verify
# The server confirms the submitted bytecode keccak-matches eth_getCode(address)
# on-chain and records the verified source + ABI. No database access required.
#
# Usage:
#   API=https://api-testnet.creditchain.org \
#   CONTRACT=src/AgentSpendVault.sol:AgentSpendVault \
#     script/verify-contract.sh 0xVault1 [0xVault2 ...]
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"

API="${API:-https://api-testnet.creditchain.org}"
CONTRACT="${CONTRACT:-src/AgentSpendVault.sol:AgentSpendVault}"
[ "$#" -ge 1 ] || { echo "usage: $0 <address> [address...]" >&2; exit 2; }

NAME="${CONTRACT##*:}"
SRC_FILE="${CONTRACT%%:*}"
ARTIFACT="out/$(basename "$SRC_FILE")/${NAME}.json"
COMPILER="${COMPILER:-}"
[ -z "$COMPILER" ] && COMPILER='v0.8.24+optimizer(1000000),via_ir=false,evm=cancun'

forge build >/dev/null
CODE="$(forge inspect "$CONTRACT" deployedBytecode)"
jq -c '.abi' "$ARTIFACT" > /tmp/.verify_abi.json

status=0
for A in "$@"; do
  REQ="$(python3 - "$CODE" "$NAME" "$SRC_FILE" "$COMPILER" <<'PY'
import sys, json, pathlib
code, name, src_file, compiler = sys.argv[1:5]
print(json.dumps({
    "contract_name": name,
    "compiler_version": compiler,
    "source_code": pathlib.Path(src_file).read_text(),
    "abi": json.loads(pathlib.Path("/tmp/.verify_abi.json").read_text()),
    "deployed_bytecode": code,
    "optimizer_enabled": True,
    "optimizer_runs": 1000000,
    "evm_version": "cancun",
}))
PY
)"
  RES="$(curl -sS -m30 -X POST -H 'content-type: application/json' --data "$REQ" "$API/v1/contracts/$A/verify")"
  LINE="$(printf '%s' "$RES" | python3 -c 'import sys,json
d=json.load(sys.stdin)
print(("✓ VERIFIED" if d.get("verified") else "✗ "+d.get("message","rejected")))' 2>/dev/null || echo "✗ $RES")"
  printf '  %s -> %s\n' "$A" "$LINE"
  printf '%s' "$LINE" | grep -q VERIFIED || status=1
done
rm -f /tmp/.verify_abi.json
exit $status
