#!/usr/bin/env bash
# Verify a deployed contract on the CreditChain explorer by EXACT bytecode match.
#
# Real verification, not a trust-me flag: it recompiles the local source with the
# project's pinned settings, compares the result to the on-chain deployedBytecode
# byte-for-byte, and only then emits SQL that records the verified source + ABI in
# the cc-browser indexer database. Apply the SQL with psql (or pipe to the
# indexer's postgres). Self-serve HTTP verification is a planned API follow-up.
#
# Usage:
#   RPC_URL=https://testnet.creditchain.org \
#   CONTRACT=src/AgentSpendVault.sol:AgentSpendVault \
#     script/verify-contract.sh 0xVault1 [0xVault2 ...] > verify.sql
#
#   # then, where the indexer DB is reachable:
#   psql "$DATABASE_URL" -f verify.sql
#   # or on the host:
#   docker exec -i cc-browser-<net>-postgres psql -U creditchain \
#     -d creditchain_browser_<net> < verify.sql
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"

RPC_URL="${RPC_URL:-https://testnet.creditchain.org}"
CONTRACT="${CONTRACT:-src/AgentSpendVault.sol:AgentSpendVault}"
[ "$#" -ge 1 ] || { echo "usage: $0 <address> [address...]" >&2; exit 2; }

SRC_FILE="${CONTRACT%%:*}"
NAME="${CONTRACT##*:}"
ARTIFACT="out/$(basename "$SRC_FILE")/${NAME}.json"

forge build >/dev/null
LOCAL="$(forge inspect "$CONTRACT" deployedBytecode)"
HASH="$(cast keccak "$LOCAL")"

for A in "$@"; do
  ONCHAIN="$(cast code "$A" --rpc-url "$RPC_URL")"
  if [ "$ONCHAIN" != "$LOCAL" ]; then
    echo "✗ bytecode MISMATCH for $A — not verifying" >&2
    exit 1
  fi
  echo "✓ exact match: $A ($(( (${#LOCAL}-2)/2 )) bytes)" >&2
done

# Build the SQL with Python so the multi-line source and JSON ABI embed safely
# in postgres dollar-quoted literals.
jq -c '.abi' "$ARTIFACT" > /tmp/.verify_abi.json
COMPILER="$(jq -r '"v"+(.metadata|fromjson|.compiler.version) ' "$ARTIFACT" 2>/dev/null || echo v0.8.24)"
python3 - "$HASH" "$NAME" "$SRC_FILE" "$COMPILER" "$@" <<'PY'
import sys, pathlib
hash_, name, src_file, compiler = sys.argv[1:5]
addrs = sys.argv[5:]
src = pathlib.Path(src_file).read_text()
abi = pathlib.Path("/tmp/.verify_abi.json").read_text().strip()
assert "$ASV_SRC$" not in src and "$ASV_ABI$" not in abi
print(f"-- {name} verification — exact deployedBytecode match ({compiler})")
for a in addrs:
    print(f"""UPDATE contracts SET
  verified = TRUE, contract_name = '{name}', compiler_version = '{compiler}',
  bytecode_hash = '{hash_}',
  abi = $ASV_ABI${abi}$ASV_ABI$::jsonb,
  source_code = $ASV_SRC${src}$ASV_SRC$,
  updated_at = now()
WHERE lower(address) = lower('{a}');""")
PY
rm -f /tmp/.verify_abi.json
