#!/usr/bin/env bash
# shellcheck disable=SC2015  # "A && B || C" below: B is say/warn (printf), which cannot fail
# install-main.sh -- the installer proper. Started by install.sh, which has
# already put the repo in $YTS_SRC_ROOT and a tarball of it at $YTS_TARBALL.
#
# Environment (all optional; set them to skip the matching prompt):
#   YTS_VMID YTS_HOSTNAME YTS_STORAGE YTS_BRIDGE YTS_IP (CIDR or "dhcp") YTS_GW
#   YTS_ALLOWED (comma list) YTS_RAM YTS_CORES YTS_DISK YTS_TEMPLATE_STORAGE
#   YTS_NONINTERACTIVE=1   no whiptail; unanswered questions take the defaults
#   YTS_ACCEPT_CLUSTER_FW=1  non-interactive consent to enabling the datacenter firewall
#   YTS_DRY_RUN=1          print the .fw file and the pct commands, change nothing
set -Eeuo pipefail

SRC_ROOT=${YTS_SRC_ROOT:?run install.sh, not this file}
TARBALL=${YTS_TARBALL:?run install.sh, not this file}
DRY_RUN=${YTS_DRY_RUN:-0}
EGRESS_PORTS=${YTS_EGRESS_PORTS:-80,443}
HERE="$SRC_ROOT/proxmox"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m/!\\\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mxxx\033[0m %s\n' "$*" >&2; exit 1; }
run() { if [[ $DRY_RUN -eq 1 ]]; then printf '+'; printf ' %q' "$@"; printf '\n'; else "$@"; fi; }

INTERACTIVE=0
if [[ -t 0 && -t 1 && ${YTS_NONINTERACTIVE:-0} != 1 && $DRY_RUN -eq 0 ]] && command -v whiptail >/dev/null; then
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
        val=$(whiptail --title "ytserver installer" --inputbox "$2" 12 72 "$3" 3>&1 1>&2 2>&3) || die "cancelled"
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
VMID=${YTS_VMID:-}; CT_NAME=${YTS_HOSTNAME:-}; STORAGE=${YTS_STORAGE:-}; BRIDGE=${YTS_BRIDGE:-}
IPCFG=${YTS_IP:-}; GW=${YTS_GW:-}; ALLOWED_CSV=${YTS_ALLOWED:-}; RAM=${YTS_RAM:-}; CORES=${YTS_CORES:-}; DISK=${YTS_DISK:-}
TSTORE=${YTS_TEMPLATE_STORAGE:-}

NEXTID=100
command -v pvesh >/dev/null && NEXTID=$(pvesh get /cluster/nextid)
ask VMID "Container ID (VMID):" "$NEXTID"
ask CT_NAME "Hostname:" "ytserver"
if [[ -z $STORAGE ]]; then
    mapfile -t STORES < <(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')
    [[ $DRY_RUN -eq 1 && ${#STORES[@]} -eq 0 ]] && STORES=(local-lvm)
    (( ${#STORES[@]} )) || die "no active storage can hold container disks"
    if [[ $INTERACTIVE -eq 1 && ${#STORES[@]} -gt 1 ]]; then
        items=(); for s in "${STORES[@]}"; do items+=("$s" ""); done
        STORAGE=$(whiptail --title "ytserver installer" --menu "Storage for the container disk:" 16 60 6 "${items[@]}" 3>&1 1>&2 2>&3) || die "cancelled"
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
        if whiptail --title "ytserver installer" --yesno "Use a STATIC IP for the container? (recommended -- the iPhone tweak needs a fixed address, and the firewall pins it)" 11 72; then
            IPCFG=""; ask IPCFG "Container IP with prefix (e.g. 192.168.0.50/24):" ""
        else IPCFG=dhcp; fi
    else IPCFG=dhcp; fi
fi
ask GW "Gateway (also the container's DNS server):" "${DETECT_GW}"
ask ALLOWED_CSV "Client IPs allowed to connect on tcp/8080 (comma list):" "192.168.0.88"
ask RAM "RAM in MB:" "1024"
ask CORES "CPU cores:" "1"
ask DISK "Disk in GB:" "8"

# ------------------------------------------------------------- validate
[[ $VMID =~ ^[0-9]{3,9}$ ]] || die "VMID must be a number >= 100"
[[ $DRY_RUN -eq 1 ]] || pvesh get /cluster/nextid --vmid "$VMID" >/dev/null 2>&1 || die "VMID $VMID is already in use"
[[ $CT_NAME =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || die "bad hostname '$CT_NAME'"
[[ $BRIDGE =~ ^[a-zA-Z0-9_.-]+$ ]] || die "bad bridge name"
[[ $DRY_RUN -eq 1 ]] || ip link show "$BRIDGE" >/dev/null 2>&1 || die "bridge $BRIDGE does not exist"
valid_ipv4 "$GW" || die "gateway '$GW' is not an IPv4 address"
is_int "$RAM" && is_int "$CORES" && is_int "$DISK" || die "RAM, cores and disk must be numbers"
(( RAM >= 512 && DISK >= 4 )) || die "need at least 512 MB RAM and 4 GB disk (ffmpeg + cache)"
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
    valid_cidr "$IPCFG" || die "container IP must look like 192.168.0.50/24 (got '$IPCFG')"
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
   container : CT ${VMID} "${CT_NAME}", unprivileged, nesting off, ${CORES} core / ${RAM} MB / swap 512 MB / ${DISK} GB on ${STORAGE}
   network   : ${BRIDGE}, ${IPCFG}, gateway/DNS ${GW}, host firewall ON (${HERE##*/}/fw.sh rules)
   clients   : ${ALLOWED[*]} -> tcp/8080 only; everything else inbound dropped
   egress    : DNS to ${GW}; internet tcp ${EGRESS_PORTS}; LAN, Tailscale, host (${HOST_IPS[*]}) blocked
   source    : ${REPO_OWNER:-?}/${REPO_NAME:-?}@${REPO_BRANCH:-?}
EOF
if [[ $INTERACTIVE -eq 1 ]]; then
    whiptail --title "ytserver installer" --yesno "Create container ${VMID} with the plan shown in the terminal?" 8 64 || die "cancelled"
fi

# ------------------------------------------------------------- datacenter firewall
cluster_fw_ensure

# ------------------------------------------------------------- template
say "Debian 12 template"
if [[ $DRY_RUN -eq 1 ]]; then
    TEMPLATE="${TSTORE}:vztmpl/debian-12-standard_12.x-x_amd64.tar.zst"
else
    pveam update >/dev/null 2>&1 || warn "pveam update failed; using the cached list"
    TNAME=$(pveam available --section system | awk '$2 ~ /^debian-12-standard/ {print $2}' | sort -V | tail -1)
    [[ -n $TNAME ]] || die "no debian-12-standard template available"
    pveam list "$TSTORE" | awk '{print $1}' | grep -q "/${TNAME}\$" || pveam download "$TSTORE" "$TNAME"
    TEMPLATE="${TSTORE}:vztmpl/${TNAME}"
fi

# ------------------------------------------------------------- create
if [[ $DHCP -eq 1 ]]; then NETCONF="name=eth0,bridge=${BRIDGE},ip=dhcp,firewall=1,type=veth"
else NETCONF="name=eth0,bridge=${BRIDGE},ip=${IPCFG},gw=${GW},firewall=1,type=veth"; fi
say "creating container ${VMID}"
run pct create "$VMID" "$TEMPLATE" \
    --hostname "$CT_NAME" --unprivileged 1 --features nesting=0 \
    --cores "$CORES" --memory "$RAM" --swap 512 --rootfs "${STORAGE}:${DISK}" \
    --net0 "$NETCONF" --nameserver "$GW" --onboot 1 --start 0 \
    --tags ios6-revival --description "ios6-revival ytserver (created by proxmox/install.sh; firewall: /etc/pve/firewall/${VMID}.fw)"

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
tcp_open() { pct exec "$VMID" -- timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" >/dev/null 2>&1; }
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
    printf 'YTS_GW=%s\nYTS_ALLOWED=%s\nYTS_HOST_IPS=%s\nYTS_DHCP=%s\nYTS_DISK_GB=%s\n' \
        "$GW" "$(IFS=,; echo "${ALLOWED[*]}")" "$(IFS=,; echo "${HOST_IPS[*]}")" "$DHCP" "$DISK"
    printf 'YTS_EGRESS_PORTS=%s\nREPO_OWNER=%s\nREPO_NAME=%s\nREPO_BRANCH=%s\n' \
        "$EGRESS_PORTS" "${REPO_OWNER:-}" "${REPO_NAME:-}" "${REPO_BRANCH:-}"
    [[ -z ${YTS_SELFTEST_PATH:-} ]] || printf "YTS_SELFTEST_PATH='%s'\n" "$YTS_SELFTEST_PATH"
} > "$ENVF"
say "provisioning inside the container (apt, deno, venv, units; takes a few minutes)"
run pct push "$VMID" "$TARBALL" /root/ytserver-src.tgz
run pct push "$VMID" "$ENVF" /root/ytserver-setup.env --perms 0600
run pct exec "$VMID" -- bash -c 'set -e; mkdir -p /root/ytsetup; tar -xzf /root/ytserver-src.tgz -C /root/ytsetup --strip-components=1; bash /root/ytsetup/proxmox/container-setup.sh /root/ytserver-setup.env'

# ------------------------------------------------------------- report
if [[ $DRY_RUN -eq 1 ]]; then DONE_MSG="DRY RUN -- nothing was changed. ytserver would be up in container"; else DONE_MSG="ytserver is up in container"; fi
GREEN=$(printf '\033[1;32m'); RESET=$(printf '\033[0m')
cat <<EOF

${GREEN}============================================================${RESET}
 ${DONE_MSG} ${VMID} (${CT_NAME})
${GREEN}============================================================${RESET}
 Container IP : ${CT_IP}
 Health check : http://${CT_IP}:8080/healthz     (from an allowed client)
 Tweak setting: ServerURL = http://${CT_IP}:8080
                in /var/mobile/Library/Preferences/com.stevenjc.ios6revival.youtube.plist

 Firewall (host-enforced, /etc/pve/firewall/${VMID}.fw):
   IN  : tcp/8080 from ${ALLOWED[*]} only; all else dropped
   OUT : DNS to ${GW} only; internet tcp ${EGRESS_PORTS}; dropped: 10/8, 172.16/12,
         192.168/16, 100.64/10 (Tailscale), 169.254/16, multicast, reserved,
         the Proxmox host (${HOST_IPS[*]}); IPv6 dropped entirely
   guard: ipfilter + macfilter (no IP/MAC spoofing), no DHCP/NDP/RA tricks
 Datacenter firewall: ON with ACCEPT/ACCEPT (host behaviour unchanged)

 Prove it   : bash -c "\$(curl -fsSL https://raw.githubusercontent.com/${REPO_OWNER:-<owner>}/${REPO_NAME:-<repo>}/${REPO_BRANCH:-main}/proxmox/verify-isolation.sh)" _ ${VMID}
 Logs       : pct exec ${VMID} -- journalctl -u ytserver -f
 Shell      : pct enter ${VMID}      (no SSH, root password locked)
 Updates    : daily ytserver-update.timer, rolls back on a failed self-test
EOF
[[ $DHCP -eq 0 ]] || warn "DHCP: reserve ${CT_IP} on your router, or edit the ipset in /etc/pve/firewall/${VMID}.fw whenever it changes."
