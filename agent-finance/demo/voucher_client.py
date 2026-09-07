#!/usr/bin/env python3
"""Reference off-chain voucher client for AgentClearing — zero dependencies.

The economic claim behind AgentClearing is that an agent can issue a payment
without touching the chain. That claim is only worth anything if issuing a
payment is genuinely cheap and genuinely local, so this client carries its own
keccak-256 and secp256k1 rather than importing a toolchain: an agent that can
run Python can pay, with no node, no RPC, and no wallet software.

Everything here is checkable against the chain — `digest` output must equal
`voucherDigest()` on-chain, and a bad signature is simply rejected by `redeem`.
Run `selftest` to check the primitives against known vectors before trusting it.

Keys are read from the VOUCHER_KEY environment variable, never from argv, so
they do not appear in the process table.

Testnet tooling. Test CCC has no monetary value.
"""

import hashlib
import hmac
import json
import os
import sys
import time

# ---------------------------------------------------------------------------
# keccak-256 (the original Keccak padding, not SHA3-256)
# ---------------------------------------------------------------------------

_MASK = (1 << 64) - 1
_RC = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
]
_ROT = [
    [0, 36, 3, 41, 18],
    [1, 44, 10, 45, 2],
    [62, 6, 43, 15, 61],
    [28, 55, 25, 21, 56],
    [27, 20, 39, 8, 14],
]


def _rol(x, n):
    return ((x << n) | (x >> (64 - n))) & _MASK if n else x


def _keccak_f(a):
    for rnd in range(24):
        c = [a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4] for x in range(5)]
        d = [c[(x - 1) % 5] ^ _rol(c[(x + 1) % 5], 1) for x in range(5)]
        for x in range(5):
            for y in range(5):
                a[x][y] ^= d[x]

        b = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                b[y][(2 * x + 3 * y) % 5] = _rol(a[x][y], _ROT[x][y])

        for x in range(5):
            for y in range(5):
                a[x][y] = b[x][y] ^ ((~b[(x + 1) % 5][y] & _MASK) & b[(x + 2) % 5][y])

        a[0][0] ^= _RC[rnd]
    return a


def keccak256(data: bytes) -> bytes:
    rate = 136
    a = [[0] * 5 for _ in range(5)]

    padded = bytearray(data)
    padded.append(0x01)
    while len(padded) % rate:
        padded.append(0x00)
    padded[-1] ^= 0x80

    for off in range(0, len(padded), rate):
        block = padded[off:off + rate]
        for i in range(rate // 8):
            a[i % 5][i // 5] ^= int.from_bytes(block[i * 8:i * 8 + 8], "little")
        _keccak_f(a)

    out = b"".join(a[i % 5][i // 5].to_bytes(8, "little") for i in range(4))
    return out[:32]


# ---------------------------------------------------------------------------
# secp256k1 — Jacobian coordinates so a signature costs one field inversion
# ---------------------------------------------------------------------------

_P = 2**256 - 2**32 - 977
_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
_GX = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
_GY = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8


def _dbl(x1, y1, z1):
    if not y1 or not z1:
        return (0, 0, 0)
    a = y1 * y1 % _P
    b = 4 * x1 * a % _P
    c = 8 * a * a % _P
    d = 3 * x1 * x1 % _P
    x3 = (d * d - 2 * b) % _P
    return (x3, (d * (b - x3) - c) % _P, 2 * y1 * z1 % _P)


def _add(x1, y1, z1, x2, y2, z2):
    if not z1:
        return (x2, y2, z2)
    if not z2:
        return (x1, y1, z1)
    z1z1, z2z2 = z1 * z1 % _P, z2 * z2 % _P
    u1, u2 = x1 * z2z2 % _P, x2 * z1z1 % _P
    s1, s2 = y1 * z2 * z2z2 % _P, y2 * z1 * z1z1 % _P
    if u1 == u2:
        return _dbl(x1, y1, z1) if s1 == s2 else (0, 0, 0)
    h = (u2 - u1) % _P
    i = 4 * h * h % _P
    j = h * i % _P
    r = 2 * (s2 - s1) % _P
    v = u1 * i % _P
    x3 = (r * r - j - 2 * v) % _P
    y3 = (r * (v - x3) - 2 * s1 * j) % _P
    z3 = ((z1 + z2) * (z1 + z2) - z1z1 - z2z2) % _P * h % _P
    return (x3, y3, z3)


def _mul(k, px, py):
    rx = ry = rz = 0
    qx, qy, qz = px, py, 1
    while k:
        if k & 1:
            rx, ry, rz = _add(rx, ry, rz, qx, qy, qz)
        qx, qy, qz = _dbl(qx, qy, qz)
        k >>= 1
    if not rz:
        return (0, 0)
    zi = pow(rz, _P - 2, _P)
    zi2 = zi * zi % _P
    return (rx * zi2 % _P, ry * zi2 % _P * zi % _P)


def _rfc6979_k(priv: int, digest: bytes) -> int:
    """Deterministic nonce. A repeated nonce leaks the private key outright, so
    this derives it from the key and message rather than trusting a PRNG."""
    v = b"\x01" * 32
    k = b"\x00" * 32
    pb = priv.to_bytes(32, "big")
    for byte in (b"\x00", b"\x01"):
        k = hmac.new(k, v + byte + pb + digest, hashlib.sha256).digest()
        v = hmac.new(k, v, hashlib.sha256).digest()
    while True:
        v = hmac.new(k, v, hashlib.sha256).digest()
        cand = int.from_bytes(v, "big")
        if 0 < cand < _N:
            return cand
        k = hmac.new(k, v + b"\x00", hashlib.sha256).digest()
        v = hmac.new(k, v, hashlib.sha256).digest()


def sign(digest: bytes, priv: int) -> bytes:
    """65-byte r||s||v over an already-hashed 32-byte digest."""
    z = int.from_bytes(digest, "big")
    k = _rfc6979_k(priv, digest)
    while True:
        rx, ry = _mul(k, _GX, _GY)
        r = rx % _N
        if r:
            s = pow(k, _N - 2, _N) * (z + r * priv) % _N
            if s:
                recid = (ry & 1) | (2 if rx >= _N else 0)
                # Reject the malleable upper-half s, matching the contract.
                if s > _N // 2:
                    s, recid = _N - s, recid ^ 1
                return r.to_bytes(32, "big") + s.to_bytes(32, "big") + bytes([27 + recid])
        k = (k + 1) % _N


def recover(digest: bytes, sig: bytes) -> str:
    """Address that produced `sig` over `digest`, or "" if the signature is
    malformed. A payee runs this before accepting a voucher: the chain will
    reject a bad one anyway, but by then the service has already been rendered."""
    if len(sig) != 65:
        return ""
    r = int.from_bytes(sig[:32], "big")
    s_ = int.from_bytes(sig[32:64], "big")
    recid = sig[64] - 27
    if not (0 < r < _N) or not (0 < s_ <= _N // 2) or recid not in (0, 1, 2, 3):
        return ""

    x = r + (_N if recid & 2 else 0)
    if x >= _P:
        return ""
    y = pow((x * x * x + 7) % _P, (_P + 1) // 4, _P)
    if (y * y - x * x * x - 7) % _P:
        return ""          # r is not on the curve
    if (y & 1) != (recid & 1):
        y = _P - y

    e = int.from_bytes(digest, "big")
    rinv = pow(r, _N - 2, _N)
    # Q = r^-1 * (s*R - e*G)
    sx, sy = _mul(s_ * rinv % _N, x, y)
    gx, gy = _mul((_N - e) * rinv % _N, _GX, _GY)
    qx, qy, qz = _add(sx, sy, 1, gx, gy, 1)
    if not qz:
        return ""
    zi = pow(qz, _P - 2, _P)
    zi2 = zi * zi % _P
    qx, qy = qx * zi2 % _P, qy * zi2 % _P * zi % _P
    body = keccak256(qx.to_bytes(32, "big") + qy.to_bytes(32, "big"))[12:]
    return _checksum("0x" + body.hex())


def address_of(priv: int) -> str:
    x, y = _mul(priv, _GX, _GY)
    body = keccak256(x.to_bytes(32, "big") + y.to_bytes(32, "big"))[12:]
    return _checksum("0x" + body.hex())


def _checksum(addr: str) -> str:
    low = addr[2:].lower()
    h = keccak256(low.encode()).hex()
    return "0x" + "".join(c.upper() if c.isalpha() and int(h[i], 16) >= 8 else c
                          for i, c in enumerate(low))


# ---------------------------------------------------------------------------
# The AgentClearing voucher — EIP-712, mirroring src/AgentClearing.sol
# ---------------------------------------------------------------------------

_VOUCHER_TYPEHASH = keccak256(b"Voucher(uint256 channelId,uint256 cumulative)")
_DOMAIN_TYPEHASH = keccak256(
    b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
)


def domain_separator(chain_id: int, contract: str) -> bytes:
    return keccak256(
        _DOMAIN_TYPEHASH
        + keccak256(b"CreditChain AgentClearing")
        + keccak256(b"1")
        + chain_id.to_bytes(32, "big")
        + bytes(12) + bytes.fromhex(contract[2:].lower())
    )


def voucher_digest(chain_id: int, contract: str, channel_id: int, cumulative: int) -> bytes:
    struct_hash = keccak256(
        _VOUCHER_TYPEHASH
        + channel_id.to_bytes(32, "big")
        + cumulative.to_bytes(32, "big")
    )
    return keccak256(b"\x19\x01" + domain_separator(chain_id, contract) + struct_hash)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _key() -> int:
    raw = os.environ.get("VOUCHER_KEY")
    if not raw:
        sys.exit("set VOUCHER_KEY (hex private key); it is never read from argv")
    return int(raw, 16)


def _selftest() -> int:
    vectors = {
        b"": "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        b"abc": "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45",
        b"a" * 135: "34367dc248bbd832f4e3e69dfaac2f92638bd0bbd18f2912ba4ef454919cf446",
        b"a" * 136: "a6c4d403279fe3e0af03729caada8374b5ca54d8065329a3ebcaeb4b60aa386e",
        b"a" * 137: "d869f639c7046b4929fc92a4d988a8b22c55fbadb802c0c66ebcd484f1915f39",
    }
    bad = 0
    for msg, want in vectors.items():
        got = keccak256(msg).hex()
        mark = "ok" if got == want else "MISMATCH"
        if got != want:
            bad += 1
        print(f"  keccak256({len(msg)}B) {mark}")

    # A known key -> known address pins the curve arithmetic and the hash together.
    k = 0x4646464646464646464646464646464646464646464646464646464646464646
    want_addr = "0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F"
    got_addr = address_of(k)
    print(f"  address_of(known key) {'ok' if got_addr == want_addr else 'MISMATCH ' + got_addr}")
    if got_addr != want_addr:
        bad += 1

    # Sign then recover: this closes the loop locally, so a broken curve
    # implementation fails here rather than as a mystery revert on-chain.
    for msg in (b"creditchain", b"", b"\xff" * 64):
        d = keccak256(msg)
        sig = sign(d, k)
        back = recover(d, sig)
        low_s = int.from_bytes(sig[32:64], "big") <= _N // 2
        good = len(sig) == 65 and low_s and back == want_addr
        print(f"  sign/recover({len(msg)}B) {'ok' if good else 'MISMATCH ' + back}")
        if not good:
            bad += 1

    # A tampered signature must not recover to the signer.
    d = keccak256(b"creditchain")
    tampered = bytearray(sign(d, k)); tampered[10] ^= 0x01
    print(f"  tampered rejected {'ok' if recover(d, bytes(tampered)) != want_addr else 'MISMATCH'}")
    if recover(d, bytes(tampered)) == want_addr:
        bad += 1

    # Upper-half s is malleable; the contract rejects it and so must the client.
    forged = sign(d, k)[:32] + (_N - int.from_bytes(sign(d, k)[32:64], "big")).to_bytes(32, "big") + b"\x1c"
    print(f"  malleable s rejected {'ok' if recover(d, forged) == '' else 'MISMATCH'}")
    if recover(d, forged) != "":
        bad += 1

    print("selftest:", "PASS" if not bad else f"FAIL ({bad})")
    return 1 if bad else 0


def main() -> int:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd = sys.argv[1]
    arg = dict(a.split("=", 1) for a in sys.argv[2:] if "=" in a)

    if cmd == "selftest":
        return _selftest()

    if cmd == "address":
        print(address_of(_key()))
        return 0

    chain = int(arg.get("chain", "0"))
    contract = arg.get("contract", "")
    channel = int(arg.get("channel", "0"))

    if cmd == "digest":
        print("0x" + voucher_digest(chain, contract, channel, int(arg["cumulative"])).hex())
        return 0

    if cmd == "stream":
        # Issue `count` successive vouchers, each superseding the last. Only the
        # final one is ever sent to the chain; the rest exist to show that the
        # marginal cost of a payment is a local signature and nothing else.
        step = int(arg["step"])
        count = int(arg["count"])
        priv = _key()
        started = time.time()
        cumulative = 0
        sig = b""
        for _ in range(count):
            cumulative += step
            sig = sign(voucher_digest(chain, contract, channel, cumulative), priv)
        elapsed = time.time() - started
        print(json.dumps({
            "payer": address_of(priv),
            "count": count,
            "cumulative": str(cumulative),
            "signature": "0x" + sig.hex(),
            "seconds": round(elapsed, 3),
            "ms_per_payment": round(elapsed * 1000 / count, 3),
            "onchain_transactions": 0,
        }))
        return 0

    sys.exit(f"unknown command: {cmd}")


if __name__ == "__main__":
    raise SystemExit(main())
