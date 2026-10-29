# Mail bridge: Gmail and Outlook/Hotmail on iOS 6 Mail

iOS 6 Mail cannot sign in to Gmail or Outlook any more (both need OAuth 2.0 in a modern browser). This
container runs [email-oauth2-proxy](https://github.com/simonrob/email-oauth2-proxy) (Apache-2.0, pinned
release, one file): the phone speaks plain IMAP/SMTP to the container, the container signs in to Google or
Microsoft with OAuth and relays the mail. iCloud and Yahoo need no server: see [ACCOUNTS.md](ACCOUNTS.md).

```
iPhone 4 (192.168.0.88)  --plain IMAP/SMTP, LAN only-->  mail container  --TLS 993/465/587 + OAuth-->  Google / Microsoft
```

This is its own container. It shares nothing with the YouTube container or any other (own CT ID, own
firewall file, own user, own token store).

## What you need first (once, in your own browser)

Follow [ACCOUNTS.md](ACCOUNTS.md) to create the Google Cloud OAuth client and/or the Microsoft Entra app
registration. You end up with a **client ID** (and, for Google, a **client secret**). They are typed into the
installer and stored only inside the container (0640 file, readable by root and the service user only). They are
never in this repo.

## Install (as root on the Proxmox host)

```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/stevenjc2009-byte/ios6-revival/main/proxmox/mail/install.sh)"
```

or from a checkout: `./proxmox/mail/install.sh`. Rehearse without changing anything: `MAILP_DRY_RUN=1 ./proxmox/mail/install.sh`.

It asks for (defaults in brackets): container ID [next free one, from `pvesh get /cluster/nextid`], hostname
[mailproxy], storage, bridge, IP or DHCP and gateway, the allowed client [192.168.0.88], your Gmail and/or Outlook
address(es), and the client ID/secret for each. Secrets are typed hidden. Every question can be preset with a
`MAILP_*` variable (list at the top of `install-main.sh`); `MAILP_LOCAL_TLS=1` also offers TLS to the phone.

It creates an unprivileged Debian 12 container (512 MB, 1 core, 4 GB), writes the host firewall, installs the
pinned proxy and proves from inside that the firewall works. It also enables the datacenter firewall if it is off
(it asks first; policy stays ACCEPT for the host) and may add a host forward rule if Docker is present (asks).

## Sign the accounts in (once)

```
pct enter <VMID>
mail-authorise
```

1. Type a **phone password** twice (10+ characters, no `"` or `\`). It is *not* your Google/Microsoft password. It
   is never stored: it encrypts the stored OAuth tokens and is what you type into iOS Mail.
2. For each account the proxy prints a long `https://accounts.google.com/...` or `https://login.microsoftonline.com/...`
   URL. Open it **in your own browser**, sign in, allow access. (Google: "Google hasn't verified this app", click
   Advanced, then "Go to ... (unsafe)"; that is your own app.)
3. The browser then fails to load a page at `http://localhost/?code=...`. That is expected. Copy the **whole address**
   from the address bar and paste it back into the terminal, Enter. You have 10 minutes per account.
4. `[OK] ... signed in` appears and the service restarts. Do the next account.

Change the phone password later, or re-sign-in: `mail-authorise --reset you@gmail.com` (omit the address for all).

## iOS 6 Mail settings

Settings > Mail, Contacts, Calendars > Add Account > Other > Add Mail Account. Name: anything. Address: your real
address. Password: the **phone password**. Tap Next, choose **IMAP**, then fill in:

| | Gmail | Outlook / Hotmail |
|---|---|---|
| Incoming host name | `<container IP>` | `<container IP>` |
| Incoming user name | full address, e.g. `you@gmail.com` | full address |
| Incoming password | phone password | phone password |
| Outgoing host name | `<container IP>` | `<container IP>` |
| Outgoing user name / password | full address / phone password | same |

iOS Mail first tries SSL; when it says it cannot connect securely, choose **Continue without SSL** (or set it by
hand). Afterwards, per account: Settings > Mail, Contacts, Calendars > the account > Account > **Advanced** and
Account > SMTP > Primary Server:

| | Gmail | Outlook / Hotmail |
|---|---|---|
| IMAP: Use SSL | **OFF** | **OFF** |
| IMAP: Authentication | Password | Password |
| IMAP: Server Port | **1143** | **2143** |
| SMTP: Use SSL | **OFF** | **OFF** |
| SMTP: Authentication | Password | Password |
| SMTP: Server Port | **1465** | **2587** |

Both accounts can live on the phone side by side (different ports). Plain text on the home LAN is the default
because iOS 6's TLS is old (see the TLS option below); the upstream legs (container to Google/Microsoft) are always
TLS 1.2+. The firewall lets only the allowed client IP reach these four ports.

If a login fails the proxy needs the phone password you chose, not the provider's. If it keeps failing after you
changed the phone password, run `mail-authorise --reset <address>`.

### Optional: TLS between the phone and the container

Install with `MAILP_LOCAL_TLS=1`. The container makes a self-signed RSA-2048/SHA-256 certificate for its IP (10
years). Then **Use SSL ON** on all four settings (same ports). iOS 6 must trust the certificate: copy it out with
`pct pull <VMID> /etc/mailproxy/tls/cert.pem cert.crt`, put it somewhere the phone can open it (web server on your PC,
or email it to yourself from another account), open it in Safari and tap Install. **Untested on a real iPhone 4.** If
it will not trust the certificate, drop back to plain.

## Security model

- **Host firewall** (`/etc/pve/firewall/<VMID>.fw`, enforced outside the container): inbound only from the allowed IP,
  only the mail ports. Outbound: DNS to the gateway only; TCP 443, 993 and (if configured) 465/587 to the internet;
  everything private (10/8, 172.16/12, 192.168/16, 100.64/10, link-local, multicast), the Proxmox host and all IPv6
  dropped. `ipfilter` + `macfilter` on. **Not per-host**: Proxmox rules match IPs, not hostnames, and Google and
  Microsoft IPs change constantly, so the container could in principle open 443/993/465/587 to any internet host. It
  cannot reach your LAN, router, Proxmox or the phone. tcp/80 is open only while installing (apt), then closed; apt uses https.
- **Service**: user `mailproxy`, no capabilities, `ProtectSystem=strict`, private `/tmp`, no devices, no new
  privileges, syscall filter, no executable-writable memory, 256 MB cap. Only `/var/lib/mailproxy` is writable.
- **Secrets**: tokens in `/var/lib/mailproxy/tokens.cache` (0700 dir), Fernet-encrypted, key derived (PBKDF2, 1.2 M
  rounds) from the phone password. The OAuth client secret is plaintext in `/etc/mailproxy/emailproxy.config`
  (0640 root:mailproxy): anyone with root on the Proxmox host or in the container can read it. A Google "Desktop app"
  client secret is not confidential in the usual sense, and it is useless without an account's consent.
- **Reviewed upstream**: stores tokens only in that file, talks only to the token endpoints and IMAP/SMTP hosts you
  configure, no telemetry or update check in `--no-gui` mode. Pinned by commit **and** sha256; the updater refuses a mismatch.
- Logging in to the proxy needs a configured account address plus the phone password, and only the allowed IP can reach
  it. Anyone on the phone's IP (or who spoofs it past `macfilter`) who knows the phone password gets your mail.
- Root in the container is locked; administer with `pct enter <VMID>` from the host. No SSH in the container.

## Check it

```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/stevenjc2009-byte/ios6-revival/main/proxmox/mail/verify-isolation.sh)" _ <VMID>
```

Every "blocked" check must PASS by timing out (a dropped packet), not by being refused. WARN lines mean "cannot be
proven from the host" (the allowed side needs the phone).

## Updates

`bash -c "$(curl -fsSL https://raw.githubusercontent.com/stevenjc2009-byte/ios6-revival/main/proxmox/mail/update.sh)" _ <VMID>`

Fetches the repo's `files/PIN`, downloads the pinned `emailproxy.py`, verifies its sha256, restarts, self-tests and
rolls back on failure, then runs `apt full-upgrade` over https. Debian security updates also apply daily on their
own (`unattended-upgrades`). Tokens and config persist: they live in `/var/lib/mailproxy` and `/etc/mailproxy`,
which updates never touch. To adopt a newer upstream release: review the diff, change the three lines in `files/PIN`
together, run the update. Nothing updates the proxy by itself.

Logs: `pct exec <VMID> -- journalctl -u mailproxy -f`. Tokens and passwords are never logged (no `--debug`).

## Uninstall

```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/stevenjc2009-byte/ios6-revival/main/proxmox/mail/uninstall.sh)" _ <VMID>
```

Destroys that container (only if tagged `ios6-revival`; list shows names so you pick the mail one), including the
tokens and client secret, and removes its firewall file. It does not revoke the grants: see "Removing access" in ACCOUNTS.md.

## Files

`install.sh` (bootstrap) > `install-main.sh` (host side) > `container-setup.sh` (inside) · `fw.sh` · `verify-isolation.sh`
· `update.sh` · `uninstall.sh` · `files/`: `PIN`, `mailproxy.service`, `mailproxy-update`, `mail-authorise`.

## Not tested on real hardware

The install, firewall, systemd sandbox, real Google/Microsoft sign-in and a real iPhone 4 connecting were not run
by the author of this change. What was run: the pinned proxy on a PC against the real provider greetings (the
phone-facing ports relay `* OK` and `220` and each login reaches the authorisation request), `bash -n` and shellcheck on every
script. Treat the first install as the test, and run `verify-isolation.sh`.
