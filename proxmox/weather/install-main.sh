#!/usr/bin/env bash
# shellcheck disable=SC2015  # "A && B || C" below: B is say/warn (printf), which cannot fail
# install-main.sh -- the installer proper. Started by install.sh, which has
# already put the repo in $WXS_SRC_ROOT and a tarball of proxmox/weather at $WXS_TARBALL.
#
# Environment (all optional; set them to skip the matching prompt):
#   WXS_VMID WXS_HOSTNAME WXS_STORAGE WXS_BRIDGE WXS_IP (CIDR or "dhcp") WXS_GW
#   WXS_ALLOWED (comma list) WXS_PORT WXS_RAM WXS_CORES WXS_DISK WXS_TEMPLATE_STORAGE
#   WXS_NONINTERACTIVE=1   no whiptail; unanswered questions take the defaults
#   WXS_ACCEPT_CLUSTER_FW=1  non-interactive consent to enabling the datacenter firewall
#   WXS_ACCEPT_HOST_FORWARD=1  non-interactive consent to the Docker FORWARD fix (fw.sh)
#   WXS_DRY_RUN=1          print the .fw file and the pct commands, change nothing
set -Eeuo pipefail

SRC_ROOT=${WXS_SRC_ROOT:?run install.sh, not this file}
TARBALL=${WXS_TARBALL:?run install.sh, not this file}
DRY_RUN=${WXS_DRY_RUN:-0}
EGRESS_PORTS=${WXS_EGRESS_PORTS:-80,443}   # tightened to 443 once the container proves apt works over https
HERE="$SRC_ROOT/proxmox/weather"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m/!\\\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mxxx\033[0m %s\n' "$*" >&2; exit 1; }
run() { if [[ $DRY_RUN -eq 1 ]]; then printf '+'; printf ' %q' "$@"; printf '\n'; else "$@"; fi; }

INTERACTIVE=0
if [[ -t 0 && -t 1 && ${WXS_NONINTERACTIVE:-0} != 1 && $DRY_RUN -eq 0 ]] && command -v whiptail >/dev/null; then
    INTERACTIVE=1
fi

# confirm_yes ENVVAR : typed "yes" interactively; non-interactive needs ENVVAR=1.
confirm_yes() {
    local ans
    if [[ ${!1:-0} == 1 ]]; then say "consent given via $1=1"; return 0; fi
    [[ $INTERACTIVE -eq 1 || -t 0 ]] || die "non-interactive run needs $1=1 to consent to this change"
    read -r -p " Type 'yes' to continue: " ans
    [[ $ans == yes ]] || die "not confirmed -- nothing was changed"
}

ask() { # ask VAR "prompt" "default"
    local var=$1 val
    [[ -z ${!var:-} ]] || return 0
    if [[ $INTERACTIVE -eq 1 ]]; then
        val=$(whiptail --title "wxserver installer" --inputbox "$2" 12 72 "$3" 3>&1 1>&2 2>&3) || die "cancelled"
    else val=$3; fi
    printf -v "$var" '%s' "$val"
}

valid_ipv4() { local o IFS=.; [[ $1 =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1; for o in $1; do ((10#$o <= 255)) || return 1; done; }
valid_cidr() { valid_ipv4 "${1%/*}" && [[ $1 == */* && ${1#*/} =~ ^[0-9]+$ ]] && ((${1#*/} >= 8 && ${1#*/} <= 30)); }
is_int() { [[ $1 =~ ^[0-9]+$ ]]; }

# ------------------------------------------------------------- preflight
if [[ $DRY_RUN -eq 0 ]]; then
    [[ $EUID -eq 0 ]] || die "run as root on the Proxmox host"
    command -v pct >/dev/null && command -v pveam >/dev/null && command -v pvesh >/dev/null || die "not a Proxmox host"
else
    warn "DRY RUN: nothing will be created, written or changed"
fi
# shellcheck source=fw.sh
. "$HERE/fw.sh"

# ------------------------------------------------------------- questions
VMID=${WXS_VMID:-}; CT_NAME=${WXS_HOSTNAME:-}; STORAGE=${WXS_STORAGE:-}; BRIDGE=${WXS_BRIDGE:-}
IPCFG=${WXS_IP:-}; GW=${WXS_GW:-}; ALLOWED_CSV=${WXS_ALLOWED:-}; RAM=${WXS_RAM:-}; CORES=${WXS_CORES:-}; DISK=${WXS_DISK:-}
TSTORE=${WXS_TEMPLATE_STORAGE:-}; PORT=${WXS_PORT:-}

# Next free id from Proxmox. If the YouTube server (CT 109) is there and 110 is
# free, this one takes 110 so the two sit side by side.
NEXTID=100
command -v pvesh >/dev/null && NEXTID=$(pvesh get /cluster/nextid)
if [[ $DRY_RUN -eq 0 ]] && pct config 109 >/dev/null 2>&1 && pvesh get /cluster/nextid --vmid 110 >/dev/null 2>&1; then
    NEXTID=110
fi
ask VMID "Container ID (VMID):" "$NEXTID"
ask CT_NAME "Hostname:" "wxserver"
if [[ -z $STORAGE ]]; then
    mapfile -t STORES < <(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')
    [[ $DRY_RUN -eq 1 && ${#STORES[@]} -eq 0 ]] && STORES=(local-lvm)
    (( ${#STORES[@]} )) || die "no active storage can hold container disks"
    if [[ $INTERACTIVE -eq 1 && ${#STORES[@]} -gt 1 ]]; then
        items=(); for s in "${STORES[@]}"; do items+=("$s" ""); done
        STORAGE=$(whiptail --title "wxserver installer" --menu "Storage for the container disk:" 16 60 6 "${items[@]}" 3>&1 1>&2 2>&3) || die "cancelled"
    else STORAGE=${STORES[0]}; fi
fi
if [[ -z $TSTORE ]]; then
    TSTORE=$(pvesm status --content vztmpl 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}' | grep -x local || true)
    [[ -n $TSTORE ]] || TSTORE=$(pvesm status --content vztmpl 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}' || true)
    TSTORE=${TSTORE:-local}
fi
ask BRIDGE "Network bridge:" "vmbr0"

DETECT_GW=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}' || true)
if [[ -z $IPCFG ]]; then
    if [[ $INTERACTIVE -eq 1 ]]; then
        if whiptail --title "wxserver installer" --yesno "Use a STATIC IP for the container? (recommended -- the iPhone tweak needs a fixed address, and the firewall pins it)" 11 72; then
            IPCFG=""; ask IPCFG "Container IP with prefix (e.g. 192.168.0.51/24; NOT the YouTube server's address):" ""
        else IPCFG=dhcp; fi
    else IPCFG=dhcp; fi
fi
ask GW "Gateway (also the container's DNS server):" "${DETECT_GW}"
ask PORT "Service port:" "8000"
ask ALLOWED_CSV "Client IPs allowed to connect on tcp/${PORT} (comma list):" "192.168.0.88"
ask RAM "RAM in MB:" "1024"
ask CORES "CPU cores:" "1"
ask DISK "Disk in GB:" "6"

# ------------------------------------------------------------- validate
[[ $VMID =~ ^[0-9]{3,9}$ ]] || die "VMID must be a number >= 100"
[[ $DRY_RUN -eq 1 ]] || pvesh get /cluster/nextid --vmid "$VMID" >/dev/null 2>&1 || die "VMID $VMID is already in use"
[[ $CT_NAME =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || die "bad hostname '$CT_NAME'"
[[ $BRIDGE =~ ^[a-zA-Z0-9_.-]+$ ]] || die "bad bridge name"
[[ $DRY_RUN -eq 1 ]] || ip link show "$BRIDGE" >/dev/null 2>&1 || die "bridge $BRIDGE does not exist"
valid_ipv4 "$GW" || die "gateway '$GW' is not an IPv4 address"
is_int "$RAM" && is_int "$CORES" && is_int "$DISK" && is_int "$PORT" || die "RAM, cores, disk and port must be numbers"
(( PORT >= 1024 && PORT <= 65535 )) || die "port must be 1024-65535 (the service runs without privileges)"
(( RAM >= 512 && DISK >= 4 )) || die "need at least 512 MB RAM and 4 GB disk"
[[ $EGRESS_PORTS =~ ^(80,443|443)$ ]] || die "WXS_EGRESS_PORTS must be '80,443' or '443'"
IFS=',' read -r -a ALLOWED <<< "${ALLOWED_CSV// /}"
(( ${#ALLOWED[@]} )) || die "at least one allowed client IP is required"
for c in "${ALLOWED[@]}"; do
    valid_ipv4 "$c" || die "allowed client '$c' is not an IPv4 address"
    [[ $c != 0.0.0.0 && $c != "$GW" ]] || die "allowed client '$c' makes no sense"
done
DHCP=0; CT_IP=""
if [[ $IPCFG == dhcp ]]; then
    DHCP=1
    warn "DHCP chosen: the container's IP can change, which breaks the tweak AND the firewall ipset. Make a DHCP reservation."
else
    valid_cidr "$IPCFG" || die "container IP must look like 192.168.0.51/24 (got '$IPCFG')"
    CT_IP=${IPCFG%/*}
    [[ $CT_IP != "$GW" ]] || die "container IP equals the gateway"
    for c in "${ALLOWED[@]}"; do [[ $c != "$CT_IP" ]] || die "container IP equals an allowed client"; done
    [[ $DRY_RUN -eq 1 ]] || ! ping -c1 -W1 "$CT_IP" >/dev/null 2>&1 || die "$CT_IP already answers ping -- pick a free address"
fi
mapfile -t HOST_IPS < <(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | sort -u)
(( ${#HOST_IPS[@]} )) || HOST_IPS=("192.0.2.1")
[[ $DRY_RUN -eq 1 ]] || command -v pveversion >/dev/null || die "pveversion missing"

cat <<EOF

 PLAN
   container : CT ${VMID} "${CT_NAME}", unprivileged, nesting on (systemd sandboxing needs it), ${CORES} core / ${RAM} MB / swap 512 MB / ${DISK} GB on ${STORAGE}
   network   : ${BRIDGE}, ${IPCFG}, gateway/DNS ${GW}, host firewall ON (${HERE##*/}/fw.sh rules)
   clients   : ${ALLOWED[*]} -> tcp/${PORT} only; everything else inbound dropped
   egress    : DNS to ${GW}; internet tcp ${EGRESS_PORTS} while installing, then tcp 443 only if apt works over https;
               LAN, Tailscale, host (${HOST_IPS[*]}) blocked. (Proxmox cannot filter by hostname: "any public IP on 443".)
   server    : TestOrig/YQL-X-Server-New (GPL-3) pinned + tree-hash checked, weather via Open-Meteo, stocks via Yahoo (yfinance)
   not touched: the YouTube server container (CT 109 or whatever it is) and its firewall file
   source    : ${REPO_OWNER:-?}/${REPO_NAME:-?}@${REPO_BRANCH:-?}
EOF
if [[ $INTERACTIVE -eq 1 ]]; then
    whiptail --title "wxserver installer" --yesno "Create container ${VMID} with the plan shown in the terminal?" 8 64 || die "cancelled"
fi

# ------------------------------------------------------------- datacenter firewall
cluster_fw_ensure
host_forward_ensure

# ------------------------------------------------------------- template
say "Debian 12 template"
if [[ $DRY_RUN -eq 1 ]]; then
    TEMPLATE="${TSTORE}:vztmpl/debian-12-standard_12.x-x_amd64.tar.zst"
else
    pveam update >/dev/null 2>&1 || warn "pveam update failed; using the cached list"
    TNAME=$(pveam available --section system | awk '$2 ~ /^debian-12-standard/ {print $2}' | sort -V | tail -1)
    [[ -n $TNAME ]] || die "no debian-12-standard template available"
    pveam list "$TSTORE" | awk '{print $1}' | grep "/${TNAME}\$" >/dev/null || pveam download "$TSTORE" "$TNAME"
    TEMPLATE="${TSTORE}:vztmpl/${TNAME}"
fi

# ------------------------------------------------------------- create
if [[ $DHCP -eq 1 ]]; then NETCONF="name=eth0,bridge=${BRIDGE},ip=dhcp,firewall=1,type=veth"
else NETCONF="name=eth0,bridge=${BRIDGE},ip=${IPCFG},gw=${GW},firewall=1,type=veth"; fi
say "creating container ${VMID}"
run pct create "$VMID" "$TEMPLATE" \
    --hostname "$CT_NAME" --unprivileged 1 --features nesting=1 \
    --cores "$CORES" --memory "$RAM" --swap 512 --rootfs "${STORAGE}:${DISK}" \
    --net0 "$NETCONF" --nameserver "$GW" --onboot 1 --start 0 \
    --tags 'ios6-revival;ios6-weather' --description "ios6-revival weather+stocks server (created by proxmox/weather/install.sh; firewall: /etc/pve/firewall/${VMID}.fw)"

# Static: the wall exists before the first packet. DHCP: the IP is unknown until boot.
[[ $DHCP -eq 1 ]] || fw_write
say "starting container"
run pct start "$VMID"
if [[ $DRY_RUN -eq 0 ]]; then
    for _ in $(seq 1 60); do pct exec "$VMID" -- test -d /run/systemd/system &>/dev/null && break; sleep 1; done
    pct exec "$VMID" -- test -d /run/systemd/system || die "container did not boot into systemd"
    if [[ $DHCP -eq 1 ]]; then
        for _ in $(seq 1 60); do
            CT_IP=$(pct exec "$VMID" -- sh -c "ip -4 -o addr show dev eth0 | awk '{print \$4}' | cut -d/ -f1" 2>/dev/null | head -1 || true)
            [[ -n $CT_IP ]] && break; sleep 1
        done
        [[ -n $CT_IP ]] || { pct stop "$VMID"; die "no DHCP lease in 60 s"; }
        say "DHCP gave ${CT_IP}"
        fw_write
    fi
else
    [[ $DHCP -eq 0 ]] || { CT_IP="<dhcp-lease>"; fw_write; }
fi

# ------------------------------------------------------------- prove the wall BEFORE installing anything
tcp_open() { pct exec "$VMID" -- env LC_ALL=C timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" >/dev/null 2>&1; }
if [[ $DRY_RUN -eq 0 ]]; then
    say "waiting for the host firewall to apply the rules"
    fw_wait_applied || { fw_diagnose; pct stop "$VMID"; die "pve-firewall did not apply rules for CT ${VMID} -- container stopped, nothing installed. Send the diagnostics block above; remove the container with: pct destroy ${VMID}"; }
    sleep 3
    if tcp_open "${HOST_IPS[0]}" 8006; then
        pct stop "$VMID"; die "WALL FAILED: the container reached the Proxmox host ${HOST_IPS[0]}:8006. Container stopped, nothing installed."
    fi
    say "wall holds: container cannot reach the Proxmox host :8006"
    tcp_open 1.1.1.1 443 && say "internet egress works (1.1.1.1:443)" || warn "no egress to 1.1.1.1:443 yet -- provisioning may fail"
fi

# ------------------------------------------------------------- provision
ENVF=$(mktemp); trap 'rm -f "$ENVF"' EXIT
{
    printf 'WXS_GW=%s\nWXS_ALLOWED=%s\nWXS_HOST_IPS=%s\nWXS_DHCP=%s\nWXS_PORT=%s\n' \
        "$GW" "$(IFS=,; echo "${ALLOWED[*]}")" "$(IFS=,; echo "${HOST_IPS[*]}")" "$DHCP" "$PORT"
    printf 'WXS_EGRESS_PORTS=%s\n' "$EGRESS_PORTS"
} > "$ENVF"
say "provisioning inside the container (apt, python wheels, units; takes a few minutes)"
run pct push "$VMID" "$TARBALL" /root/wxserver-src.tgz
run pct push "$VMID" "$ENVF" /root/wxserver-setup.env --perms 0600
run pct exec "$VMID" -- env LC_ALL=C bash -c 'set -e; mkdir -p /root/wxsetup; tar -xzf /root/wxserver-src.tgz -C /root/wxsetup --strip-components=1; bash /root/wxsetup/proxmox/weather/container-setup.sh /root/wxserver-setup.env'

# ------------------------------------------------------------- tighten egress to 443 if apt proved https works
if [[ $DRY_RUN -eq 0 ]]; then
    FINAL=$(pct exec "$VMID" -- sh -c 'cat /root/.wxs-egress 2>/dev/null; rm -f /root/.wxs-egress' 2>/dev/null | sed -n 1p || true)
    if [[ $FINAL == 443 && $EGRESS_PORTS != 443 ]]; then
        say "apt works over https: tightening the host firewall to internet tcp 443 only"
        EGRESS_PORTS=443
        fw_write
        closed=0
        for _ in $(seq 1 12); do
            if ! tcp_open 1.1.1.1 80 && tcp_open 1.1.1.1 443; then closed=1; break; fi
            sleep 3
        done
        [[ $closed -eq 1 ]] && say "tcp 80 now blocked, tcp 443 works" \
            || warn "could not confirm 'tcp 80 blocked, tcp 443 open' after the rewrite; run verify-isolation.sh"
    else
        warn "internet tcp ${EGRESS_PORTS} stays open (apt could not use https only)"
    fi
fi

# ------------------------------------------------------------- report
if [[ $DRY_RUN -eq 1 ]]; then DONE_MSG="DRY RUN -- nothing was changed. The weather server would be up in container"; else DONE_MSG="The weather + stocks server is up in container"; fi
GREEN=$(printf '\033[1;32m'); RESET=$(printf '\033[0m')
cat <<EOF

${GREEN}============================================================${RESET}
 ${DONE_MSG} ${VMID} (${CT_NAME})
${GREEN}============================================================${RESET}
 Container IP : ${CT_IP}
 Health check : http://${CT_IP}:${PORT}/dgw     (from an allowed client; answers "ok")
 Tweak setting: Settings > Weather And Stocks > YQL Server URL = http://${CT_IP}:${PORT}
                (key CustomServer in /var/mobile/Library/Preferences/com.skyglow.yqlpreferences.plist;
                 no trailing slash). Then delete and re-add your cities: saved Yahoo ids do not map.

 Firewall (host-enforced, /etc/pve/firewall/${VMID}.fw):
   IN  : tcp/${PORT} from ${ALLOWED[*]} only; all else dropped
   OUT : DNS to ${GW} only; internet tcp ${EGRESS_PORTS}; dropped: 10/8, 172.16/12,
         192.168/16, 100.64/10 (Tailscale), 169.254/16, multicast, reserved,
         the Proxmox host (${HOST_IPS[*]}); IPv6 dropped entirely
   guard: ipfilter + macfilter (no IP/MAC spoofing), no DHCP/NDP/RA tricks
 Datacenter firewall: ON with ACCEPT/ACCEPT (host behaviour unchanged)

 Prove it   : bash -c "\$(curl -fsSL https://raw.githubusercontent.com/${REPO_OWNER:-<owner>}/${REPO_NAME:-<repo>}/${REPO_BRANCH:-main}/proxmox/weather/verify-isolation.sh)" _ ${VMID}
 Logs       : pct exec ${VMID} -- journalctl -u wxserver -f
 Shell      : pct enter ${VMID}      (no SSH, root password locked)
 Updates    : daily wxserver-update.timer (yfinance only), rolls back on a failed stock probe
EOF
[[ $DHCP -eq 0 ]] || warn "DHCP: reserve ${CT_IP} on your router, or edit the ipset in /etc/pve/firewall/${VMID}.fw whenever it changes."
