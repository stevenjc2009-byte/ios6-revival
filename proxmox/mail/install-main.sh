#!/usr/bin/env bash
# shellcheck disable=SC2015  # "A && B || C" below: B is say/warn (printf), which cannot fail
# install-main.sh -- the installer proper (mail bridge). Started by install.sh, which has already
# put the repo in $MAILP_SRC_ROOT. Copied from ../install-main.sh (copy, don't depend) and adapted.
#
# Environment (all optional; set one to skip its prompt):
#   MAILP_VMID MAILP_HOSTNAME MAILP_STORAGE MAILP_BRIDGE MAILP_IP (CIDR or "dhcp") MAILP_GW
#   MAILP_ALLOWED (comma list) MAILP_RAM MAILP_CORES MAILP_DISK MAILP_TEMPLATE_STORAGE
#   MAILP_GOOGLE_EMAILS (comma list) MAILP_GOOGLE_CLIENT_ID MAILP_GOOGLE_CLIENT_SECRET
#   MAILP_MS_EMAILS (comma list)     MAILP_MS_CLIENT_ID     MAILP_MS_CLIENT_SECRET (leave empty for a public client)
#   MAILP_LOCAL_TLS=1      also offer TLS to the phone (self-signed cert); default is plain IMAP/SMTP on the LAN
#   MAILP_NONINTERACTIVE=1 no whiptail; unanswered questions take the defaults
#   MAILP_ACCEPT_CLUSTER_FW=1 / MAILP_ACCEPT_HOST_FORWARD=1  non-interactive consent (see fw.sh)
#   MAILP_DRY_RUN=1        print the .fw file and the pct commands, change nothing
# Secrets (client id/secret) are read here, written to a 0600 temp file, pushed into the container
# with mode 0600, deleted again on both sides. They are never printed and never in the repo.
set -Eeuo pipefail

SRC_ROOT=${MAILP_SRC_ROOT:?run install.sh, not this file}
DRY_RUN=${MAILP_DRY_RUN:-0}
HERE="$SRC_ROOT/proxmox/mail"
# Local listen ports on the container (what iOS Mail connects to).
P_GIMAP=1143; P_GSMTP=1465; P_OIMAP=2143; P_OSMTP=2587

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m/!\\\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mxxx\033[0m %s\n' "$*" >&2; exit 1; }
run() { if [[ $DRY_RUN -eq 1 ]]; then printf '+'; printf ' %q' "$@"; printf '\n'; else "$@"; fi; }

INTERACTIVE=0
if [[ -t 0 && -t 1 && ${MAILP_NONINTERACTIVE:-0} != 1 && $DRY_RUN -eq 0 ]] && command -v whiptail >/dev/null; then
    INTERACTIVE=1
fi
CAN_READ=0; [[ -t 0 && ${MAILP_NONINTERACTIVE:-0} != 1 && $DRY_RUN -eq 0 ]] && CAN_READ=1

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
        val=$(whiptail --title "mail bridge installer" --inputbox "$2" 12 72 "$3" 3>&1 1>&2 2>&3) || die "cancelled"
    else val=$3; fi
    printf -v "$var" '%s' "$val"
}

# readvar VAR "prompt" [secret] : plain terminal prompt (secrets are not echoed); env value wins.
readvar() {
    local var=$1 val=""
    [[ -z ${!var:-} ]] || return 0
    if [[ $CAN_READ -eq 1 ]]; then
        if [[ ${3:-} == secret ]]; then read -r -s -p "$2" val; echo; else read -r -p "$2" val; fi
    fi
    printf -v "$var" '%s' "$val"
}

valid_ipv4() { local o IFS=.; [[ $1 =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1; for o in $1; do ((10#$o <= 255)) || return 1; done; }
valid_cidr() { valid_ipv4 "${1%/*}" && [[ $1 == */* && ${1#*/} =~ ^[0-9]+$ ]] && ((${1#*/} >= 8 && ${1#*/} <= 30)); }
is_int() { [[ $1 =~ ^[0-9]+$ ]]; }
valid_emails() { local e; IFS=',' read -r -a _E <<< "${1// /}"; for e in "${_E[@]}"; do [[ $e =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || return 1; done; }
valid_token() { [[ $1 =~ ^[A-Za-z0-9._~+/=:-]+$ ]]; }   # client ids/secrets: no spaces, quotes or shell characters

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
VMID=${MAILP_VMID:-}; CT_NAME=${MAILP_HOSTNAME:-}; STORAGE=${MAILP_STORAGE:-}; BRIDGE=${MAILP_BRIDGE:-}
IPCFG=${MAILP_IP:-}; GW=${MAILP_GW:-}; ALLOWED_CSV=${MAILP_ALLOWED:-}; RAM=${MAILP_RAM:-}; CORES=${MAILP_CORES:-}; DISK=${MAILP_DISK:-}
TSTORE=${MAILP_TEMPLATE_STORAGE:-}
G_EMAILS=${MAILP_GOOGLE_EMAILS:-}; G_ID=${MAILP_GOOGLE_CLIENT_ID:-}; G_SECRET=${MAILP_GOOGLE_CLIENT_SECRET:-}
M_EMAILS=${MAILP_MS_EMAILS:-}; M_ID=${MAILP_MS_CLIENT_ID:-}; M_SECRET=${MAILP_MS_CLIENT_SECRET:-}
LOCAL_TLS=${MAILP_LOCAL_TLS:-0}

NEXTID=100
command -v pvesh >/dev/null && NEXTID=$(pvesh get /cluster/nextid)     # asks Proxmox for a free ID
ask VMID "Container ID (VMID):" "$NEXTID"
ask CT_NAME "Hostname:" "mailproxy"
if [[ -z $STORAGE ]]; then
    mapfile -t STORES < <(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')
    [[ $DRY_RUN -eq 1 && ${#STORES[@]} -eq 0 ]] && STORES=(local-lvm)
    (( ${#STORES[@]} )) || die "no active storage can hold container disks"
    if [[ $INTERACTIVE -eq 1 && ${#STORES[@]} -gt 1 ]]; then
        items=(); for s in "${STORES[@]}"; do items+=("$s" ""); done
        STORAGE=$(whiptail --title "mail bridge installer" --menu "Storage for the container disk:" 16 60 6 "${items[@]}" 3>&1 1>&2 2>&3) || die "cancelled"
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
        if whiptail --title "mail bridge installer" --yesno "Use a STATIC IP for the container? (recommended -- iOS Mail needs a fixed address, and the firewall pins it)" 11 72; then
            IPCFG=""; ask IPCFG "Container IP with prefix (e.g. 192.168.0.51/24):" ""
        else IPCFG=dhcp; fi
    else IPCFG=dhcp; fi
fi
ask GW "Gateway (also the container's DNS server):" "${DETECT_GW}"
ask ALLOWED_CSV "Client IPs allowed to connect to the bridge ports (comma list):" "192.168.0.88"
ask RAM "RAM in MB:" "512"
ask CORES "CPU cores:" "1"
ask DISK "Disk in GB:" "4"

if [[ $DRY_RUN -eq 1 && -z $G_EMAILS$M_EMAILS ]]; then G_EMAILS="dry.run@gmail.com"; G_ID=dry-run-client-id; G_SECRET=dry-run-secret; fi
if [[ -z $G_EMAILS$M_EMAILS && $CAN_READ -eq 1 ]]; then
    echo; echo " Accounts. Create the OAuth clients first: see proxmox/mail/ACCOUNTS.md. Leave a provider empty to skip it."
fi
readvar G_EMAILS " Gmail address(es), comma separated [empty = no Gmail]: "
if [[ -n $G_EMAILS ]]; then
    readvar G_ID " Google OAuth client ID: "
    readvar G_SECRET " Google OAuth client secret (not shown): " secret
fi
readvar M_EMAILS " Outlook/Hotmail address(es), comma separated [empty = no Outlook]: "
if [[ -n $M_EMAILS ]]; then
    readvar M_ID " Microsoft application (client) ID: "
    [[ $CAN_READ -eq 0 || -n $M_SECRET ]] || readvar M_SECRET " Microsoft client secret [empty = public client, no secret]: " secret
fi

# ------------------------------------------------------------- validate
[[ $VMID =~ ^[0-9]{3,9}$ ]] || die "VMID must be a number >= 100"
[[ $DRY_RUN -eq 1 ]] || pvesh get /cluster/nextid --vmid "$VMID" >/dev/null 2>&1 || die "VMID $VMID is already in use"
[[ $CT_NAME =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || die "bad hostname '$CT_NAME'"
[[ $BRIDGE =~ ^[a-zA-Z0-9_.-]+$ ]] || die "bad bridge name"
[[ $DRY_RUN -eq 1 ]] || ip link show "$BRIDGE" >/dev/null 2>&1 || die "bridge $BRIDGE does not exist"
valid_ipv4 "$GW" || die "gateway '$GW' is not an IPv4 address"
is_int "$RAM" && is_int "$CORES" && is_int "$DISK" || die "RAM, cores and disk must be numbers"
(( RAM >= 256 && DISK >= 3 )) || die "need at least 256 MB RAM and 3 GB disk"
IFS=',' read -r -a ALLOWED <<< "${ALLOWED_CSV// /}"
(( ${#ALLOWED[@]} )) || die "at least one allowed client IP is required"
for c in "${ALLOWED[@]}"; do
    valid_ipv4 "$c" || die "allowed client '$c' is not an IPv4 address"
    [[ $c != 0.0.0.0 && $c != "$GW" ]] || die "allowed client '$c' makes no sense"
done
[[ -n $G_EMAILS$M_EMAILS ]] || die "no account given: set a Gmail and/or Outlook address (prompted, or MAILP_GOOGLE_EMAILS / MAILP_MS_EMAILS)"
MPORTS=(); PROVIDERS=(); EGRESS=(443 993)
if [[ -n $G_EMAILS ]]; then
    valid_emails "$G_EMAILS" || die "bad Gmail address list '$G_EMAILS'"
    valid_token "$G_ID" && valid_token "$G_SECRET" || die "Google client ID/secret missing or contain spaces/quotes (copy them again)"
    MPORTS+=("$P_GIMAP" "$P_GSMTP"); PROVIDERS+=("Gmail"); EGRESS+=(465)
fi
if [[ -n $M_EMAILS ]]; then
    valid_emails "$M_EMAILS" || die "bad Outlook address list '$M_EMAILS'"
    valid_token "$M_ID" || die "Microsoft client ID missing or contains spaces/quotes"
    [[ -z $M_SECRET ]] || valid_token "$M_SECRET" || die "Microsoft client secret contains spaces/quotes"
    MPORTS+=("$P_OIMAP" "$P_OSMTP"); PROVIDERS+=("Outlook"); EGRESS+=(587)
fi
MAIL_PORTS_CSV=$(IFS=,; echo "${MPORTS[*]}")
FINAL_EGRESS=$(printf '%s\n' "${EGRESS[@]}" | sort -un | paste -sd,)
DHCP=0; CT_IP=""
if [[ $IPCFG == dhcp ]]; then
    DHCP=1
    warn "DHCP chosen: the container's IP can change, which breaks iOS Mail AND the firewall ipset. Make a DHCP reservation."
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
   container : CT ${VMID} "${CT_NAME}", unprivileged, nesting on (systemd sandboxing needs it), ${CORES} core / ${RAM} MB / swap 256 MB / ${DISK} GB on ${STORAGE}
   network   : ${BRIDGE}, ${IPCFG}, gateway/DNS ${GW}, host firewall ON (mail/fw.sh rules)
   accounts  : ${PROVIDERS[*]}  (client secret stays inside the container, mode 0640 root:mailproxy)
   clients   : ${ALLOWED[*]} -> tcp/${MAIL_PORTS_CSV} only; everything else inbound dropped
   egress    : DNS to ${GW}; internet tcp ${FINAL_EGRESS} (tcp/80 only while installing); LAN, Tailscale, host (${HOST_IPS[*]}) blocked
   phone side: $([[ $LOCAL_TLS == 1 ]] && echo "TLS with a self-signed certificate (MAILP_LOCAL_TLS=1)" || echo "plain IMAP/SMTP on the LAN (default; iOS Mail 'Use SSL' OFF)")
   source    : ${REPO_OWNER:-?}/${REPO_NAME:-?}@${REPO_BRANCH:-?}
EOF
if [[ $INTERACTIVE -eq 1 ]]; then
    whiptail --title "mail bridge installer" --yesno "Create container ${VMID} with the plan shown in the terminal?" 8 64 || die "cancelled"
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
    --cores "$CORES" --memory "$RAM" --swap 256 --rootfs "${STORAGE}:${DISK}" \
    --net0 "$NETCONF" --nameserver "$GW" --onboot 1 --start 0 \
    --tags ios6-revival --description "ios6-revival mail bridge (created by proxmox/mail/install.sh; firewall: /etc/pve/firewall/${VMID}.fw)"

# While installing, tcp/80 is open for apt; it is removed again after provisioning.
MAIL_PORTS=$MAIL_PORTS_CSV
EGRESS_PORTS="${FINAL_EGRESS},80"
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
TARBALL=$(mktemp); ENVF=$(mktemp); trap 'rm -f "$ENVF" "$TARBALL"' EXIT
chmod 0600 "$ENVF"
tar -C "$SRC_ROOT" -czf "$TARBALL" proxmox/mail
{
    printf 'MAILP_GW=%q\nMAILP_ALLOWED=%q\nMAILP_HOST_IPS=%q\nMAILP_DHCP=%q\n' \
        "$GW" "$(IFS=,; echo "${ALLOWED[*]}")" "$(IFS=,; echo "${HOST_IPS[*]}")" "$DHCP"
    printf 'MAILP_EGRESS_PORTS=%q\nMAILP_LOCAL_TLS=%q\nMAILP_CT_IP=%q\n' "$FINAL_EGRESS" "$LOCAL_TLS" "$CT_IP"
    printf 'MAILP_GOOGLE_EMAILS=%q\nMAILP_GOOGLE_CLIENT_ID=%q\nMAILP_GOOGLE_CLIENT_SECRET=%q\n' "$G_EMAILS" "$G_ID" "$G_SECRET"
    printf 'MAILP_MS_EMAILS=%q\nMAILP_MS_CLIENT_ID=%q\nMAILP_MS_CLIENT_SECRET=%q\n' "$M_EMAILS" "$M_ID" "$M_SECRET"
    printf 'P_GIMAP=%s\nP_GSMTP=%s\nP_OIMAP=%s\nP_OSMTP=%s\n' "$P_GIMAP" "$P_GSMTP" "$P_OIMAP" "$P_OSMTP"
} > "$ENVF"
say "provisioning inside the container (apt, proxy download + sha256 check, units; takes a few minutes)"
run pct push "$VMID" "$TARBALL" /root/mailproxy-src.tgz
run pct push "$VMID" "$ENVF" /root/mailproxy-setup.env --perms 0600
run pct exec "$VMID" -- env LC_ALL=C bash -c 'set -e; mkdir -p /root/mailsetup; tar -xzf /root/mailproxy-src.tgz -C /root/mailsetup; bash /root/mailsetup/proxmox/mail/container-setup.sh /root/mailproxy-setup.env'
rm -f "$ENVF"

# ------------------------------------------------------------- final firewall (tcp/80 closed again)
EGRESS_PORTS=$FINAL_EGRESS
fw_write
if [[ $DRY_RUN -eq 0 ]]; then
    say "waiting for the final rules (tcp/80 closed) and re-checking the container's reach"
    sleep 15
    if tcp_open 1.1.1.1 80; then warn "tcp/80 still reachable from the container -- the reload may not have landed yet; run verify-isolation.sh"; fi
    pct exec "$VMID" -- apt-get update -qq >/dev/null 2>&1 && say "apt over https still works with only ${FINAL_EGRESS} open" \
        || warn "apt-get update failed with only ${FINAL_EGRESS} open -- security updates would stall; see README (Updates)"
fi

# ------------------------------------------------------------- report
if [[ $DRY_RUN -eq 1 ]]; then DONE_MSG="DRY RUN -- nothing was changed. The mail bridge would be up in container"; else DONE_MSG="The mail bridge is installed in container"; fi
GREEN=$(printf '\033[1;32m'); RESET=$(printf '\033[0m')
cat <<EOF

${GREEN}============================================================${RESET}
 ${DONE_MSG} ${VMID} (${CT_NAME})
${GREEN}============================================================${RESET}
 Container IP : ${CT_IP}
 NEXT STEP    : sign the accounts in (once; needs your own browser):
                    pct enter ${VMID}
                    mail-authorise
 Phone ports  : $([[ -n $G_EMAILS ]] && echo "Gmail IMAP ${P_GIMAP}, SMTP ${P_GSMTP}.  ")$([[ -n $M_EMAILS ]] && echo "Outlook IMAP ${P_OIMAP}, SMTP ${P_OSMTP}.")
                (server = ${CT_IP}; iOS Mail 'Use SSL' $([[ $LOCAL_TLS == 1 ]] && echo ON || echo OFF); exact fields in proxmox/mail/README.md)
 Firewall (host-enforced, /etc/pve/firewall/${VMID}.fw):
   IN  : tcp/${MAIL_PORTS_CSV} from ${ALLOWED[*]} only; all else dropped
   OUT : DNS to ${GW} only; internet tcp ${FINAL_EGRESS}; dropped: 10/8, 172.16/12, 192.168/16,
         100.64/10 (Tailscale), 169.254/16, multicast, reserved, the Proxmox host (${HOST_IPS[*]}); IPv6 dropped
   guard: ipfilter + macfilter. Not per-host: Proxmox rules cannot filter by hostname.
 Prove it   : bash -c "\$(curl -fsSL https://raw.githubusercontent.com/${REPO_OWNER:-<owner>}/${REPO_NAME:-<repo>}/${REPO_BRANCH:-main}/proxmox/mail/verify-isolation.sh)" _ ${VMID}
 Logs       : pct exec ${VMID} -- journalctl -u mailproxy -f
 Update     : bash -c "\$(curl -fsSL https://raw.githubusercontent.com/${REPO_OWNER:-<owner>}/${REPO_NAME:-<repo>}/${REPO_BRANCH:-main}/proxmox/mail/update.sh)" _ ${VMID}
EOF
[[ $DHCP -eq 0 ]] || warn "DHCP: reserve ${CT_IP} on your router, or edit the ipset in /etc/pve/firewall/${VMID}.fw whenever it changes."
