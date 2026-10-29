# Safari root certificates (Mozilla's list)

iOS 6 ships 2013 root certificates, so sites whose chain ends at a newer root
show "Cannot Verify Server Identity". `trustroots.py` adds every root in
Mozilla's list (the `cacert.pem` in the `certifi` package) to the phone's
trust store. Every app that checks certificates the normal way (Safari, Mail,
App Store, TLSFix) then trusts them.

Installed 2026-10-29 from certifi 2026.10.23 (cacert.pem sha256
`2ef52ad5…44bd2b`): 96 added, 22 were already there, 128 rows in total.

## Update or reinstall

On the PC (Python 3.11+, `pip install cryptography certifi`):

```bash
scp -O root@192.168.0.88:/private/var/Keychains/TrustStore.sqlite3 TrustStore.sqlite3
cp TrustStore.sqlite3 TrustStore.sqlite3.bak
python trustroots.py TrustStore.sqlite3 "$(python -c 'import certifi; print(certifi.where())')"
scp -O TrustStore.sqlite3 root@192.168.0.88:/private/var/tmp/TrustStore.sqlite3
```

On the phone (SSH as root):

```sh
K=/private/var/Keychains
cp /private/var/tmp/TrustStore.sqlite3 $K/TrustStore.sqlite3.new
chown _securityd:wheel $K/TrustStore.sqlite3.new; chmod 600 $K/TrustStore.sqlite3.new
mv $K/TrustStore.sqlite3.new $K/TrustStore.sqlite3; killall securityd
```

Running it again adds only roots that are new.

## Undo

The store from before is kept on the phone at
`/private/var/root/TrustStore.sqlite3.before-mozilla` (and on the PC in
`D:\claude-archive\iphone4-backup\2026-10-29\`). Copy it back with the same
four phone lines above, using that file instead.

## How a row is built

Table `tsettings`: `sha1` = SHA-1 of the certificate, `data` = the
certificate, `tset` = an empty plist array (always trust), `subj` = the
subject as iOS looks issuers up: the outer SEQUENCE dropped, PrintableString
values trimmed, whitespace collapsed and uppercased, UTF8String values as-is.
This matches all 32 rows already on the phone, and `tests/` checks it.

## Verified on the phone

- A small SecTrust probe (same call TLSFix makes) on www.ssl.com's chain:
  old store "untrusted" (result 5), new store "trusted" (result 4).
- Safari: www.ssl.com showed "Cannot Verify Server Identity" before, and its
  page loads with the lock after. www.harica.gr (a 2021 ECC root) loads with
  the lock. The syslog shows no trust failures after the install.
