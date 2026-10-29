# ios6-revival — interfaces every part must keep

Owner: steve. iPhone 4 (iPhone3,1), iOS 6.1.3, jailbroken, at 192.168.0.88.

## Layout
- `server/` — the YouTube translation server (Python 3.11, Debian 12 target).
- `tweak/` — Theos tweak that sends the YouTube app's API traffic to the server.
- `proxmox/` — Proxmox VE helper script that builds the locked-down container and installs `server/`.

## Server contract
- Start: `python -m ytserver` from `server/` (package dir `server/ytserver/`). Dependencies in `server/requirements.txt`.
- Needs `ffmpeg` and `deno` on PATH (yt-dlp uses deno for YouTube's JS challenges).
- Environment variables (all optional):
  - `YTS_BIND` default `0.0.0.0`
  - `YTS_PORT` default `8080`
  - `YTS_CACHE_DIR` default `./cache` (video files + metadata cache)
  - `YTS_CACHE_MAX_MB` default `4096`
  - `YTS_MAX_HEIGHT` default `360` (iPhone 4 safe; 480 allowed)
  - `YTS_PUBLIC_URL` default derived from the request Host header — base URL put into returned feed/stream links.
- `GET /healthz` → `200 ok` (plain text). Used by the installer and the updater self-test.
- Plain HTTP only. Same paths as the real GData v2 API (`/feeds/api/...`) so the tweak only swaps the host.

## Tweak contract
- Rewrites requests the YouTube app makes to `gdata.youtube.com` (and any other hosts the app uses for its API, thumbnails or playback) to the server base URL, keeping path and query.
- Server base URL read from `/var/mobile/Library/Preferences/com.stevenjc.ios6revival.youtube.plist`, key `ServerURL` (string, e.g. `http://192.168.0.50:8080`). Default when missing: `http://127.0.0.1:8080`.
- Package id `com.stevenjc.ios6revival.youtube`, arch `iphoneos-arm`, armv7, deployment target iOS 6.0, deb built with gzip compression.

## Container contract (installer)
- Service user `ytserver`, no login. Code in `/opt/ytserver`, cache in `/var/cache/ytserver`, venv `/opt/ytserver/venv`.
- systemd unit `ytserver.service`; listens on 8080.
- Reachable only from the allowed client IPs (default `192.168.0.88`) on tcp/8080; may reach the internet but nothing on the LAN except the gateway's DNS.
