"""Add Mozilla's root certificates to an iOS 6 TrustStore.sqlite3 (Safari, Mail and every app).

iOS 6 keeps user-trusted roots in /private/var/Keychains/TrustStore.sqlite3, table tsettings:
  sha1  SHA-1 of the certificate DER (primary key)
  subj  the subject Name, normalised the way iOS looks issuers up: outer SEQUENCE dropped and
        PrintableString values trimmed, whitespace runs collapsed, uppercased; other values as-is
  tset  trust settings plist; an empty <array/> means "always trust as a root"
  data  the certificate DER
Rows already in the file are left alone. Works on a copy; the phone side is in README.md.

    python trustroots.py TrustStore.sqlite3 cacert.pem
"""
from __future__ import annotations

import base64
import hashlib
import re
import sqlite3
import sys
from pathlib import Path

from cryptography import x509

TSET = (b'<?xml version="1.0" encoding="UTF-8"?>\n'
        b'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        b'"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        b'<plist version="1.0">\n<array/>\n</plist>\n')

PRINTABLE_STRING = 0x13


def _tlv(buf: bytes, pos: int) -> tuple[int, bytes, int]:
    """One DER element at pos: (tag, contents, position after it)."""
    tag, length = buf[pos], buf[pos + 1]
    pos += 2
    if length & 0x80:
        n = length & 0x7F
        length = int.from_bytes(buf[pos:pos + n], "big")
        pos += n
    return tag, buf[pos:pos + length], pos + length


def _encode(tag: int, contents: bytes) -> bytes:
    n = len(contents)
    if n < 0x80:
        return bytes([tag, n]) + contents
    size = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([tag, 0x80 | len(size)]) + size + contents


def _children(contents: bytes) -> list[tuple[int, bytes]]:
    out, pos = [], 0
    while pos < len(contents):
        tag, body, pos = _tlv(contents, pos)
        out.append((tag, body))
    return out


def _normalise_value(tag: int, body: bytes) -> bytes:
    # Checked against the 32 rows already on the phone: UTF8String values keep their case.
    if tag != PRINTABLE_STRING:
        return _encode(tag, body)
    text = re.sub(r"\s+", " ", body.decode("ascii").strip()).upper()
    return _encode(tag, text.encode("ascii"))


def normalised_subject(cert: x509.Certificate) -> bytes:
    """The subj column for a certificate."""
    tag, name, _ = _tlv(cert.subject.public_bytes(), 0)
    assert tag == 0x30, "subject is not a SEQUENCE"
    rdns = b""
    for set_tag, rdn in _children(name):
        atvs = b""
        for seq_tag, atv in _children(rdn):
            (oid_tag, oid), (val_tag, val) = _children(atv)
            atvs += _encode(seq_tag, _encode(oid_tag, oid) + _normalise_value(val_tag, val))
        rdns += _encode(set_tag, atvs)
    return rdns


def read_pem(path: Path) -> list[bytes]:
    """Every certificate in a PEM bundle, as DER."""
    blocks = re.findall(rb"-----BEGIN CERTIFICATE-----(.+?)-----END CERTIFICATE-----",
                        path.read_bytes(), re.S)
    return [base64.b64decode(b"".join(block.split())) for block in blocks]


def add_roots(db: Path, ders: list[bytes]) -> tuple[int, int]:
    """Insert the certificates not already in db; returns (added, already there)."""
    con = sqlite3.connect(db)
    try:
        have = {row[0] for row in con.execute("SELECT sha1 FROM tsettings")}
        added = 0
        for der in ders:
            sha1 = hashlib.sha1(der).digest()
            if sha1 in have:
                continue
            subj = normalised_subject(x509.load_der_x509_certificate(der))
            con.execute("INSERT INTO tsettings (sha1, subj, tset, data) VALUES (?, ?, ?, ?)",
                        (sha1, subj, TSET, der))
            have.add(sha1)
            added += 1
        con.commit()
        return added, len(ders) - added
    finally:
        con.close()


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[-1].strip())
        return 2
    added, kept = add_roots(Path(argv[1]), read_pem(Path(argv[2])))
    print(f"added {added}, already there {kept}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
