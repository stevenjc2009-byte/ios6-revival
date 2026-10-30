# ios6-revival

Brings the original YouTube app back to life on a jailbroken iPhone running iOS 6, using a server you host yourself.

| Part | What it does |
|---|---|
| [`server/`](server/) | Python server that speaks the old YouTube GData v2 API the app expects, and serves videos as iPhone 4–friendly MP4 (H.264/AAC, ≤360p). |
| [`tweak/`](tweak/) | Theos tweak for the YouTube app that sends its API, thumbnail and sign-in traffic to your server. |
| [`autoclose/`](autoclose/) | SpringBoard tweak: when you open an app and 5 or more are running, closes all the others (keeps the one you're on and the one playing audio). |
| [`notify/`](notify/) | SpringBoard tweak: a banner when an app is installed or updated, plus the `revnotify "Title" "Message"` command for scripts. |
| [`logwatch/`](logwatch/) | Phone Log: logs only warnings, errors and crashes; hourly size check, banner at the limit, deletes the log after the set days. |
| [`proxmox/`](proxmox/) | One-command installer that builds a locked-down Proxmox container for the server. |

## Install the server on Proxmox

Run on the Proxmox host as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/stevenjc2009-byte/ios6-revival/main/proxmox/install.sh)"
```

The container is unprivileged and firewalled by the Proxmox host. Only the allowed iPhone can reach it on tcp/8080, and it can reach only DNS on the gateway plus web ports on the internet. Nothing else on the LAN is reachable. Afterwards, run `proxmox/verify-isolation.sh <VMID>` on the host to check this. See [`proxmox/README.md`](proxmox/README.md).

## Install the tweak

Install `tweak/packages/com.stevenjc.ios6revival.youtube_*.deb` on the phone with `dpkg -i`. Then set the server address in **Settings → YouTube Revival → Server**, for example `http://192.168.0.50:8080`.

## Install Auto Close Apps

Install `autoclose/packages/com.stevenjc.ios6revival.autoclose_*.deb` with `dpkg -i`, then respring. Change the limit in **Settings → Auto Close Apps**.

## Install Revival Notify and Phone Log

Install `notify/packages/com.stevenjc.ios6revival.notify_*.deb` first, then `logwatch/packages/com.stevenjc.ios6revival.logwatch_*.deb`, with `dpkg -i`, then respring. Set the warning size and days in **Settings → Phone Log**. `revlogwatch status` shows the current size and deletion time. Removing Phone Log puts the original `/etc/syslog.conf` back.

## Install Clear Caches

Install `cacheclean/packages/com.stevenjc.ios6revival.cacheclean_*.deb` with `dpkg -i`. Open **Settings → Clear Caches** and tap **Clear** to delete Maps tiles, app launch pictures and ad caches; an alert shows how much was freed. `revcacheclean -n` lists the files without deleting them.
