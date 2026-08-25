#!/usr/bin/env python3
"""Independent WOTS+ reference implementation (RFC 8391 §3.1, keccak256, n=32, w=16).

Written from the specification rather than from WOTSPlus.sol, so that agreement
between the two is evidence the construction is right and not merely that one
file is self-consistent. It emits test vectors consumed by WOTSPlus.t.sol.

Also acts as the signer: WOTS+ signing must happen OFF-CHAIN (the secret key must
never touch a transaction), so a reference signer is a required deliverable, not
just a test aid.
"""
import hashlib
import json
import sys

W, LEN1, LEN2 = 16, 64, 3
LEN = LEN1 + LEN2

D_F, D_PRF, D_PK = b"\x00", b"\x03", b"\x07"


def keccak(b: bytes) -> bytes:
    # Ethereum uses original Keccak padding, NOT the later NIST SHA3 padding.
    try:
        from Crypto.Hash import keccak as _k
        return _k.new(digest_bits=256, data=b).digest()
    except ImportError:
        pass
    try:
        import sha3  # pysha3
        return sha3.keccak_256(b).digest()
    except ImportError:
        pass
    # Pure-python fallback so the reference never silently depends on a wheel.
    return _keccak256_pure(b)


def _keccak256_pure(msg: bytes) -> bytes:
    RC = [0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
          0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
          0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
          0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
          0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
          0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008]
    ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61],
           [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]]
    M = (1 << 64) - 1
    rol = lambda x, n: ((x << n) | (x >> (64 - n))) & M

    def f(A):
        for rnd in range(24):
            C = [A[x][0] ^ A[x][1] ^ A[x][2] ^ A[x][3] ^ A[x][4] for x in range(5)]
            D = [C[(x - 1) % 5] ^ rol(C[(x + 1) % 5], 1) for x in range(5)]
            for x in range(5):
                for y in range(5):
                    A[x][y] ^= D[x]
            B = [[0] * 5 for _ in range(5)]
            for x in range(5):
                for y in range(5):
                    B[y][(2 * x + 3 * y) % 5] = rol(A[x][y], ROT[x][y])
            for x in range(5):
                for y in range(5):
                    A[x][y] = B[x][y] ^ ((~B[(x + 1) % 5][y] & M) & B[(x + 2) % 5][y])
            A[0][0] ^= RC[rnd]
        return A

    rate = 136
    pad = bytearray(msg) + b"\x01"
    while len(pad) % rate != rate - 1:
        pad += b"\x00"
    pad += b"\x80"
    A = [[0] * 5 for _ in range(5)]
    for off in range(0, len(pad), rate):
        blk = pad[off:off + rate]
        for i in range(rate // 8):
            A[i % 5][i // 5] ^= int.from_bytes(blk[i * 8:i * 8 + 8], "little")
        A = f(A)
    out = b""
    for i in range(4):
        out += A[i % 5][i // 5].to_bytes(8, "little")
    return out[:32]


def prf(pub_seed: bytes, chain_index: int, step: int, j: int) -> bytes:
    return keccak(D_PRF + pub_seed
                  + chain_index.to_bytes(2, "big") + step.to_bytes(2, "big")
                  + bytes([j]))


def chain(x: bytes, start: int, end: int, pub_seed: bytes, chain_index: int) -> bytes:
    """Advance a chain value from step `start` (inclusive) to `end` (exclusive)."""
    for i in range(start, end):
        key = prf(pub_seed, chain_index, i, 0)
        mask = prf(pub_seed, chain_index, i, 1)
        x = keccak(D_F + key + bytes(a ^ b for a, b in zip(x, mask)))
    return x


def to_digits(digest: bytes) -> list:
    """Message digits plus the checksum that forces at least one chain backward."""
    digits, csum = [], 0
    for i in range(LEN1):
        d = (digest[i // 2] >> 4) & 0xF if i % 2 == 0 else digest[i // 2] & 0xF
        digits.append(d)
        csum += (W - 1) - d
    digits += [(csum >> 8) & 0xF, (csum >> 4) & 0xF, csum & 0xF]
    return digits


def keygen(secret_seed: bytes, pub_seed: bytes):
    """Derive the 67 chain starts from a single secret seed, then run them to the end."""
    sk = [keccak(b"\x04" + secret_seed + i.to_bytes(2, "big")) for i in range(LEN)]
    pk = [chain(sk[i], 0, W - 1, pub_seed, i) for i in range(LEN)]
    return sk, pk


def compress(pub_seed: bytes, pk: list) -> bytes:
    return keccak(D_PK + pub_seed + b"".join(pk))


def sign(digest: bytes, sk: list, pub_seed: bytes) -> bytes:
    digits = to_digits(digest)
    return b"".join(chain(sk[i], 0, digits[i], pub_seed, i) for i in range(LEN))


def verify(digest: bytes, sig: bytes, pub_seed: bytes, pk_hash: bytes) -> bool:
    digits = to_digits(digest)
    pk = [chain(sig[i * 32:(i + 1) * 32], digits[i], W - 1, pub_seed, i) for i in range(LEN)]
    return compress(pub_seed, pk) == pk_hash


def main():
    # Self-test first: a reference that does not verify its own signature is worthless.
    secret, pub_seed = b"\x11" * 32, b"\x22" * 32
    sk, pk = keygen(secret, pub_seed)
    pk_hash = compress(pub_seed, pk)
    msg = keccak(b"CreditChain quantum guard test vector 1")
    sig = sign(msg, sk, pub_seed)
    assert verify(msg, sig, pub_seed, pk_hash), "reference failed to verify its own signature"
    assert not verify(keccak(b"different"), sig, pub_seed, pk_hash), "reference accepted wrong digest"
    assert len(sig) == LEN * 32 == 2144

    vectors = []
    for label in (b"vector-1", b"vector-2", b"vector-3"):
        s, ps = keccak(b"sk" + label), keccak(b"ps" + label)
        sk_, pk_ = keygen(s, ps)
        d = keccak(b"msg" + label)
        vectors.append({
            "label": label.decode(),
            "secretSeed": "0x" + s.hex(),
            "pubSeed": "0x" + ps.hex(),
            "digest": "0x" + d.hex(),
            "pkHash": "0x" + compress(ps, pk_).hex(),
            "sig": "0x" + sign(d, sk_, ps).hex(),
        })

    out = {"note": "Generated by reference/wotsplus.py — independent of WOTSPlus.sol",
           "params": {"n": 32, "w": W, "len1": LEN1, "len2": LEN2, "len": LEN},
           "keccak_selfcheck": "0x" + keccak(b"").hex(),
           "vectors": vectors}
    print(json.dumps(out, indent=2))
    print("# reference self-test PASSED", file=sys.stderr)


if __name__ == "__main__":
    main()
