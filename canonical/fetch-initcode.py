#!/usr/bin/env python3
"""Fetch the init code of every contract in manifest.json and prove it authentic.

An explorer is not trusted. Each contract was created by the deterministic-deployment proxy, so
its address is keccak256(0xff ++ proxy ++ salt ++ keccak256(initCode))[12:]. If the fetched init
code reproduces the canonical address, it is exactly what was deployed; if not, it is refused.

Usage:  canonical/fetch-initcode.py            # fetch what is missing, verify everything
        canonical/fetch-initcode.py --check    # verify the stored files only, no network
Needs:  `cast` (Foundry) for keccak256; Python 3 standard library only.
"""
import json
import pathlib
import subprocess
import sys
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
MANIFEST = json.loads((HERE / "manifest.json").read_text())
STORE = HERE / "initcode"


def keccak(hexdata: str) -> str:
    return subprocess.run(["cast", "keccak", hexdata], capture_output=True, text=True, check=True).stdout.strip()


def create2(deployer: str, salt: str, initcode: str) -> str:
    h = keccak("0xff" + deployer[2:].lower() + salt[2:].lower() + keccak(initcode)[2:])
    return "0x" + h[-40:]


def fetch(source: str, address: str) -> str:
    req = urllib.request.Request(
        f"{source}/api/v2/smart-contracts/{address}", headers={"User-Agent": "creditchain-canonical"}
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        data = json.load(r)
    code = data.get("creation_bytecode") or ""
    if not code.startswith("0x") or len(code) < 4:
        raise SystemExit(f"{address}: explorer returned no creation bytecode")
    return code.lower()


def main() -> int:
    check_only = "--check" in sys.argv
    STORE.mkdir(exist_ok=True)
    ok = True
    for c in MANIFEST["contracts"]:
        path = STORE / f"{c['name']}.hex"
        if path.exists():
            initcode = path.read_text().strip()
        elif check_only:
            print(f"MISSING  {c['name']}")
            ok = False
            continue
        else:
            initcode = fetch(c["source"], c["address"])
        got = create2(MANIFEST["deployer"], c["salt"], initcode)
        if got.lower() != c["address"].lower():
            print(f"REFUSED  {c['name']}: init code gives {got}, canonical is {c['address']}")
            ok = False
            continue
        if not path.exists():
            path.write_text(initcode + "\n")
        print(f"OK       {c['name']:24} {c['address']}  initcode {keccak(initcode)}  {len(initcode)//2 - 1} bytes")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
