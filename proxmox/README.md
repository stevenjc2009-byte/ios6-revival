# ytserver on Proxmox: a locked-in container

Runs the YouTube translation server (`server/`) in its own **unprivileged LXC container**
that can only be reached by your iPhone and can only reach the internet's web ports.
If the server were ever hacked, the attacker is inside that one container and cannot
get to your router, your PCs, your iPhone, or the Proxmox host.

## Install

Run as root in the Proxmox host shell:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/stevenjc2009-byte/ios6-revival/main/proxmox/install.sh)"
```

It asks for a container ID, IP, gateway, the iPhone's IP (the only machine allowed in) and
storage. Everything has a default. For no prompts, set `YTS_*` variables first
(`YTS_VMID`, `YTS_IP`, `YTS_GW`, `YTS_ALLOWED`, `YTS_STORAGE`, `YTS_BRIDGE`,
`YTS_NONINTERACTIVE=1`, `YTS_ACCEPT_CLUSTER_FW=1`, `YTS_ACCEPT_HOST_FORWARD=1`). To rehearse
without changing anything: `YTS_DRY_RUN=1`.

**Docker on the Proxmox host:** Docker sets the iptables FORWARD policy to DROP, which cuts
every firewalled guest off the network. The installer spots this, explains, asks, then appends
`iptables -A FORWARD -m physdev --physdev-is-bridged -j ACCEPT` (after Docker's and Proxmox's
own chains, so whatever they drop stays dropped) and enables
`/etc/systemd/system/vmbr0-forward.service` to re-add it at boot. `uninstall.sh` leaves it in
place, because other guests need it too.

At the end it prints the container IP, the health URL and the `ServerURL` to put in the
tweak. Then prove the walls:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/stevenjc2009-byte/ios6-revival/main/proxmox/verify-isolation.sh)" _ <VMID>
```

## Threat model

The attacker is assumed to get **code execution as `ytserver`**, and then possibly root,
inside the container (a bug in yt-dlp, deno or the server). The goal is that
this reaches nothing else.

## The walls (outside in)

| Layer | Where it lives | Stops |
|---|---|---|
| Proxmox host firewall `/etc/pve/firewall/<VMID>.fw` | On the host. Root in the container cannot change it. | Inbound: everything except tcp/8080 from your listed clients. Outbound: everything except gateway DNS and tcp 80/443 to the public internet. The LAN (10/8, 172.16/12, 192.168/16), Tailscale/CGNAT, link-local, multicast, the Proxmox host's own addresses and all IPv6 are dropped. |
| `ipfilter` + `macfilter` | Same file | Pretending to be another IP or MAC (e.g. the router) to slip past the rules. |
| Unprivileged LXC, `nesting=1` | Container config | Container root is an ordinary unprivileged user on the host. No keyctl, fuse or device nodes. Nesting is on because Debian 12 systemd needs it for the services' sandboxing (PrivateTmp, ProtectSystem); it exposes a little more of the host's /proc and /sys. |
| No way in | Container | No sshd, no mail, no rpc/nfs. Root password locked. You get in only with `pct enter` from the host. |
| In-container nftables | `/etc/nftables.conf` | Same rules as the host, second copy. **Defence in depth only**: root inside could flush it. The host firewall is the real wall, and `verify-isolation.sh` flushes this layer on purpose to prove the host still blocks. |
| systemd sandbox | `ytserver.service` | The server runs as `ytserver` with no capabilities, read-only filesystem except its cache, private `/tmp`, IPv4 and unix sockets only, a syscall filter, 768 MB memory and 128 task limits. `MemoryDenyWriteExecute` is deliberately off because deno is a JIT (tested: on, deno crashes). |

Why drop-by-default: the host rules are `policy_in: DROP`, `policy_out: DROP` plus explicit
accepts, so a mistake blocks traffic instead of opening it. First match wins in Proxmox
rules, so the DNS accepts sit above the `192.168/16` drop.

## What this does not protect against

- A container is not a VM. All containers share the host kernel, so a kernel
  escape bug could defeat the container walls. For stronger
  isolation use a small VM (KVM) instead; the firewall file works the same way.
- The server can still reach any public web server on 80/443. That is needed for YouTube.
  It cannot use other ports, so no outbound SSH, SMTP or reverse shells on odd ports,
  but a web-port reverse shell is possible.
- Anything that can reach the iPhone's IP on the allowed list (or spoof it on the
  bridge) can talk to :8080. `ipfilter`/`macfilter` stop the spoofing.

## Change who may connect

Edit `/etc/pve/firewall/<VMID>.fw` on the host. Each client is one line:

```
IN ACCEPT -source 192.168.0.88 -p tcp -dport 8080 # allowed client (iPhone)
```

Add or change lines, save, and wait about 10 seconds (pve-firewall reloads on its own).
If you change the container's IP, change the `[IPSET ipfilter-net0]` entry too. With DHCP
the installer leaves the ipset empty and uses `dhcp: 1`; a static IP is more robust.
Re-run `verify-isolation.sh` after any edit.

## Updates

A systemd timer inside the container runs `ytserver-update` daily. It downloads the repo
tarball, builds `server/` into a new tree with the newest yt-dlp, swaps it in, then tests
`/healthz` plus one real search. If the test fails it swaps the old tree back. Skipped
when nothing changed. Run it by hand or read the log:

```bash
pct exec <VMID> -- systemctl start ytserver-update
pct exec <VMID> -- journalctl -u ytserver-update -e
pct exec <VMID> -- ytserver-update --selftest
```

Caveats: deno is pinned (v2.9.8, sha256-checked) and only changes when the installer is
updated. The tarball follows the branch, not a pinned commit, so whoever can push to the
repo's `main` can change what runs in the container (it is still walled in).

## Uninstall

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/stevenjc2009-byte/ios6-revival/main/proxmox/uninstall.sh)" _ <VMID>
```

Asks you to type `yes`, stops and destroys the container (including its disk) and deletes
its `.fw` file. It refuses containers not tagged `ios6-revival`. It leaves
`/etc/pve/firewall/cluster.fw` alone: the datacenter firewall stays on with
ACCEPT/ACCEPT, which changes nothing for the host or your other guests.

## The datacenter firewall switch

Guest firewalls only work when Datacenter > Firewall > Options is enabled. If it is off,
the installer shows exactly what it will write to `cluster.fw` (`enable: 1`, `policy_in:
ACCEPT`, `policy_out: ACCEPT`, old file backed up to `/root/cluster.fw.bak.*`) and asks
first. If it is already on, the file is not touched. If it is off but has stricter
rules of yours, the installer stops rather than risk locking you out of the web UI.
`host.fw` is never touched. The installer also refuses to provision until it has
checked that the rules are live and that the container cannot open the Proxmox web UI.

## Files

`install.sh` (bootstrap), `install-main.sh` (host side), `fw.sh` (firewall pieces),
`container-setup.sh` (inside the container), `files/` (service, updater, timer),
`verify-isolation.sh`, `uninstall.sh`.
