# ios6-revival

Brings the original YouTube app back to life on a jailbroken iPhone running iOS 6, using a server you host yourself.

| Part | What it does |
|---|---|
| [`server/`](server/) | Python server that speaks the old YouTube GData v2 API the app expects, and serves videos as iPhone 4–friendly MP4 (H.264/AAC, ≤360p). |
| [`tweak/`](tweak/) | Theos tweak for the YouTube app that sends its API, thumbnail and sign-in traffic to your server. |
| [`proxmox/`](proxmox/) | One-command installer that builds a locked-down Proxmox container for the server. |

## Install the server on Proxmox

Run on the Proxmox host as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/stevenjc2009-byte/ios6-revival/main/proxmox/install.sh)"
```

The container is unprivileged and firewalled by the Proxmox host. Only the allowed iPhone can reach it on tcp/8080, and it can reach only DNS on the gateway plus web ports on the internet. Nothing else on the LAN is reachable. Afterwards, run `proxmox/verify-isolation.sh <VMID>` on the host to check this. See [`proxmox/README.md`](proxmox/README.md).

## Install the tweak

Install `tweak/packages/com.stevenjc.ios6revival.youtube_*.deb` on the phone with `dpkg -i`. Then set the server address in **Settings → YouTube Revival → Server**, for example `http://192.168.0.50:8080`.
