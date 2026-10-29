"""trustroots: rows must match what iOS 6 already stores for the same certificates."""
import base64
import re
import sqlite3
import sys
from pathlib import Path

import certifi
import pytest
from cryptography import x509

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import trustroots  # noqa: E402

# subj blobs copied from the phone's TrustStore.sqlite3 (rows iOS itself trusts) and the expected
# value for a UTF8String name, which iOS keeps in its original case.
PHONE_SUBJ = {
    "Amazon Root CA 1": "310b3009060355040613025553310f300d060355040a1306414d415a4f4e3119301706035504031310414d415a4f4e20524f4f542043412031",
    "SSL.com TLS RSA Root CA 2022": "310b300906035504061302555331183016060355040a0c0f53534c20436f72706f726174696f6e3125302306035504030c1c53534c2e636f6d20544c532052534120526f6f742043412032303232",
}


def _bundle_cert(common_name: str) -> x509.Certificate:
    for der in trustroots.read_pem(Path(certifi.where())):
        cert = x509.load_der_x509_certificate(der)
        names = cert.subject.get_attributes_for_oid(x509.NameOID.COMMON_NAME)
        if names and names[0].value == common_name:
            return cert
    pytest.skip(f"{common_name} not in this certifi bundle")


@pytest.mark.parametrize("name", sorted(PHONE_SUBJ))
def test_subject_matches_phone(name):
    assert trustroots.normalised_subject(_bundle_cert(name)).hex() == PHONE_SUBJ[name]


def _empty_store(path: Path) -> None:
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE tsettings(sha1 BLOB NOT NULL DEFAULT '',subj BLOB NOT NULL DEFAULT '',"
                "tset BLOB,data BLOB,PRIMARY KEY(sha1))")
    con.commit()
    con.close()


def test_add_roots_is_idempotent(tmp_path):
    db = tmp_path / "TrustStore.sqlite3"
    _empty_store(db)
    ders = trustroots.read_pem(Path(certifi.where()))
    assert trustroots.add_roots(db, ders) == (len(ders), 0)
    assert trustroots.add_roots(db, ders) == (0, len(ders))
    tsets = {row[0] for row in sqlite3.connect(db).execute("SELECT tset FROM tsettings")}
    assert tsets == {trustroots.TSET}
