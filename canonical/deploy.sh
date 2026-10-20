#!/usr/bin/env bash
# Put every contract in manifest.json at its canonical address on one chain.
#
#   canonical/deploy.sh <rpc-url> --account <foundry-keystore-name>     # real networks
#   canonical/deploy.sh <rpc-url> --private-key <dev-key>               # local test chains only
#
# Each contract is created by the deterministic-deployment proxy from the init code in initcode/,
# which fetch-initcode.py has already proven against the canonical address. A contract already
# present is left alone. Whoever pays the gas, the result is the same code at the same address.
set -euo pipefail
cd "$(dirname "$0")"

RPC="${1:?usage: deploy.sh <rpc-url> --account <name> | --private-key <key>}"
shift
DEPLOYER=$(python3 -c 'import json;print(json.load(open("manifest.json"))["deployer"])')

python3 -I fetch-initcode.py --check >/dev/null || { echo "init code failed verification; refusing" >&2; exit 1; }
[ "$(cast code "$DEPLOYER" --rpc-url "$RPC")" != "0x" ] || { echo "no deterministic-deployment proxy on this chain" >&2; exit 1; }

python3 -c 'import json
for c in json.load(open("manifest.json"))["contracts"]: print(c["name"], c["address"], c["salt"])' |
while read -r name address salt; do
  if [ "$(cast code "$address" --rpc-url "$RPC")" != "0x" ]; then
    echo "present   $name  $address"
    continue
  fi
  initcode=$(tr -d '\n' < "initcode/$name.hex")
  cast send "$DEPLOYER" "${salt}${initcode#0x}" --rpc-url "$RPC" "$@" >/dev/null
  [ "$(cast code "$address" --rpc-url "$RPC")" != "0x" ] || { echo "FAILED    $name" >&2; exit 1; }
  echo "deployed  $name  $address"
done
