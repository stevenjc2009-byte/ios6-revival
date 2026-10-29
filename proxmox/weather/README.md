# Weather + Stocks server (WeatherX backend) on Proxmox

A self-hosted server for the **WeatherX** tweak (`com.skyglow.weatherx`) on the
iOS 6.1.3 iPhone 4. It answers the stock Weather and Stocks apps and the
Notification Centre widgets, so they work without Skyglow's public server.
It runs in its **own** unprivileged LXC container, separate from the YouTube
server container, behind a host-enforced firewall.

- Weather: Open-Meteo (no key, no account). City search: Open-Meteo geocoding.
- Stocks: quotes, charts and news from Yahoo through the `yfinance` library.
- Server code: [TestOrig/YQL-X-Server-New](https://github.com/TestOrig/YQL-X-Server-New)
  (GPL-3), pinned to commit `f236e98a3f4a`, checked against a tree hash at
  install time, plus a small overlay in `files/overlay/` (see "What the overlay changes").
- No API keys, no telemetry, no accounts.

## Install (run on the Proxmox host, as root)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/stevenjc2009-byte/ios6-revival/main/proxmox/weather/install.sh)"
```

Rehearse first (changes nothing, prints the firewall file and the `pct` commands):

```bash
WXS_DRY_RUN=1 bash -c "$(curl -fsSL https://raw.githubusercontent.com/stevenjc2009-byte/ios6-revival/main/proxmox/weather/install.sh)"
```

It asks for (Enter takes the default):

| Question | Default |
|---|---|
| VMID | next free id, but **110** if CT 109 (YouTube) exists and 110 is free |
| Hostname | `wxserver` |
| Network bridge | `vmbr0` |
| Static IP with prefix | none: pick a **free** address, not the YouTube container's |
| Gateway (also the container's DNS) | the host's default gateway |
| Service port | `8000` (YouTube uses 8080) |
| Client IPs allowed to connect | `192.168.0.88` (the iPhone) |
| RAM / cores / disk | 1024 MB / 1 / 6 GB |

Then it shows a PLAN, asks one typed `yes` if the datacenter firewall must be
turned on (host and other guests keep accepting everything), builds the
container, proves the firewall holds **before** installing anything, installs,
runs a self-test, and prints the address to type into the phone.

Non-interactive: set `WXS_NONINTERACTIVE=1` plus any of `WXS_VMID WXS_HOSTNAME
WXS_STORAGE WXS_BRIDGE WXS_IP WXS_GW WXS_ALLOWED WXS_PORT WXS_RAM WXS_CORES
WXS_DISK`, and `WXS_ACCEPT_CLUSTER_FW=1` / `WXS_ACCEPT_HOST_FORWARD=1` to
consent to the firewall changes without a prompt.

Run from a checkout instead of GitHub: `./proxmox/weather/install.sh`.

## Point the phone at it

On the iPhone: **Settings > Weather And Stocks > YQL Server URL**, type

```
http://<container-ip>:8000
```

- `http`, not `https` (iOS 6 cannot do modern TLS), the port, and **no
  trailing slash**. Empty means "use the default public server".
- The same field covers weather and stocks.
- The setting is the `CustomServer` key in
  `/var/mobile/Library/Preferences/com.skyglow.yqlpreferences.plist`
  (currently the phone has `ServerChoice = RequiServer` and no `CustomServer`).
- **Delete your saved cities and add them again.** This server's city ids are
  Open-Meteo ids, not Yahoo WOEIDs. A WOEID saved by the old server can point
  at a different place here (Yahoo 17044 is a village in Iran in Open-Meteo).

Check from the phone's Safari first: `http://<container-ip>:8000/dgw` must show `ok`.

## Prove the lockdown

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/stevenjc2009-byte/ios6-revival/main/proxmox/weather/verify-isolation.sh)" _ 110
```

(use your VMID). Prints PASS/FAIL per check. It refuses any container not
tagged `ios6-weather`. Every "blocked" check passes only on a **timeout** (a
real firewall drop), not on a refusal. It also flushes the container's own
firewall and shows the host wall still holds.

## Lockdown

Enforced by the Proxmox host in `/etc/pve/firewall/<VMID>.fw`; root inside the
container cannot change it.

| Direction | Allowed | Everything else |
|---|---|---|
| In | tcp/8000 from the listed client IPs only | dropped |
| Out | DNS to the gateway; internet **tcp 443** only | dropped: the Proxmox host, `10/8`, `172.16/12`, `192.168/16`, Tailscale `100.64/10`, link-local, multicast, reserved, all IPv6 |

- During install tcp 80 is open too (the Debian template's apt starts on plain
  http). Once apt has been switched to https inside the container, the host
  rewrites the rules to **443 only** and checks that port 80 is now blocked.
  If apt cannot use https, 80 stays open and the installer says so.
- Proxmox cannot filter by hostname, so "HTTPS to the data providers" really is
  "tcp 443 to any public IPv4 address". The providers are `api.open-meteo.com`,
  `geocoding-api.open-meteo.com`, `nominatim.openstreetmap.org` (reverse
  geocode for GPS lookups), Yahoo's finance hosts (used by `yfinance`),
  `pypi.org` and `codeload.github.com` at install/update time.
- `ipfilter` + `macfilter`: the container cannot spoof another IP or MAC.
- Inside: no sshd, no other listeners (checked), root password locked
  (`pct enter <VMID>` is the only way in), IPv6 off, a second nftables egress
  filter (table `wxfw`), unattended security updates.
- The service (`wxserver.service`) runs as an unprivileged system user with no
  capabilities, no new privileges, a read-only filesystem and no persistent
  write path (its caches live in a private `/tmp`), AF_INET only, a system-call
  filter, 768 MB memory cap.

## Day to day

```bash
pct exec 110 -- journalctl -u wxserver -f           # server log
pct exec 110 -- journalctl -u wxserver-update       # updater log
pct exec 110 -- /usr/local/sbin/wxserver-update --selftest   # full probe, weather + stocks
pct exec 110 -- /opt/wxserver/venv/bin/python /opt/wxserver/probe.py --base http://127.0.0.1:8000
```

**Updates.** `wxserver-update.timer` runs daily. It updates only the stock
library (`yfinance`, which breaks when Yahoo changes things): builds a copy,
upgrades it, swaps it in, runs the stock probe, and **rolls back** if that
fails. Container packages get unattended security updates. It does not touch the
server code or the overlay: to change those, re-run the installer on a fresh
container (uninstall first) after pulling a newer repo.

## Uninstall

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/stevenjc2009-byte/ios6-revival/main/proxmox/weather/uninstall.sh)" _ 110
```

Asks you to type `yes`, then stops and destroys the container and removes its
`.fw` file. It only works on containers tagged `ios6-weather`, with no override,
so it can never destroy the YouTube container. The datacenter firewall switch is
left on (it was ACCEPT/ACCEPT).

## What the overlay changes in the upstream server

The pinned upstream defaults to a geocoding backend (`apis.yzu.moe`) that is
dead. `files/apply_overlay.py` applies exact-once string patches (the install
fails if any no longer match) and copies files from `files/overlay/`:

- Geocoding: Open-Meteo search replaces the dead backend; reverse geocoding via
  Nominatim; the Yzu/GeoNames/SQLite providers are deleted.
- Query parsing: accepts the `query='NAME' limit 1` form WeatherX sends and a
  missing `lang`.
- Stocks rewritten: correct hourly cache, signed `change` and `changepercent`
  from the previous close, `name`/`exchange`/52-week range filled in, no random
  P/E or dividend numbers, NaN-safe charts, no ad item in the news.
- The install asserts no reference to `yzu.moe` is left in the code.

## Known limits

- The container installer has never run on a real Proxmox host or in a real
  Debian 12 container (`pct`, `pve-firewall`, systemd sandboxing in an
  unprivileged container). The scripts passed syntax checks, shellcheck, a dry
  run and part-by-part rehearsals, so the first install on your host is the
  first real run: run `verify-isolation.sh` straight after.
- Stocks come from Yahoo through an unofficial library: they can break, and
  Yahoo can rate-limit. News is sometimes empty.
- Weather is Open-Meteo data presented in Yahoo's format: condition codes and
  texts are mapped by the upstream server, not identical to Yahoo's.
- Weather and stock traffic between the phone and the container is plain http
  on your LAN (iOS 6 limit); only the allowed client IPs can reach it.
- aarch64 hosts: the pinned wheel list was resolved for x86_64 only.
