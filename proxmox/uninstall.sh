#!/usr/bin/env bash
# uninstall.sh -- destroy the ytserver container and its firewall file.
# Run as root on the Proxmox host:   ./uninstall.sh [VMID]
#   YTS_ASSUME_YES=1   skip the typed confirmation (non-interactive)
#   YTS_FORCE=1        allow destroying a CT that is not tagged ios6-revival
#
# Does NOT touch /etc/pve/firewall/cluster.fw or host.fw: the datacenter
# firewall stays enabled (policy ACCEPT/ACCEPT, so the host is unaffected).
# Turn it off yourself in Datacenter > Firewall > Options if you want that.
set -Eeuo pipefail

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mxxx\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root on the Proxmox host"
command -v pct >/dev/null || die "pct not found: not a Proxmox host"

VMID=${1:-${YTS_VMID:-}}
if [[ -z $VMID ]]; then
    echo "Containers tagged ios6-revival:"
    FOUND=()
    while read -r id; do
        pct config "$id" 2>/dev/null | grep -q '^tags:.*ios6-revival' && { FOUND+=("$id"); echo "  $id  $(pct config "$id" | sed -n 's/^hostname: //p')"; }
    done < <(pct list | awk 'NR>1 {print $1}')
    (( ${#FOUND[@]} )) || die "none found; pass the VMID explicitly"
    read -r -p "VMID to destroy: " VMID
fi
[[ $VMID =~ ^[0-9]+$ ]] || die "VMID must be a number"
pct config "$VMID" >/dev/null 2>&1 || die "no container $VMID on this node"

if ! pct config "$VMID" | grep -q '^tags:.*ios6-revival'; then
    [[ ${YTS_FORCE:-0} == 1 ]] || die "CT $VMID is not tagged ios6-revival, so it was not made by this installer. Set YTS_FORCE=1 if you really mean it."
fi

cat <<EOF

 ABOUT TO DESTROY
   container : CT ${VMID} ($(pct config "$VMID" | sed -n 's/^hostname: //p')), status $(pct status "$VMID")
   disk      : $(pct config "$VMID" | sed -n 's/^rootfs: //p')   (deleted with the container, unrecoverable)
   firewall  : /etc/pve/firewall/${VMID}.fw (removed)
   kept      : /etc/pve/firewall/cluster.fw and host.fw are NOT touched
EOF
if [[ ${YTS_ASSUME_YES:-0} != 1 ]]; then
    read -r -p " Type 'yes' to destroy CT ${VMID}: " ans
    [[ $ans == yes ]] || die "not confirmed; nothing was changed"
fi

if [[ $(pct status "$VMID") == *running* ]]; then
    say "stopping CT ${VMID}"
    pct stop "$VMID"
fi
say "destroying CT ${VMID}"
pct destroy "$VMID" --purge 1
rm -f "/etc/pve/firewall/${VMID}.fw"
say "done. CT ${VMID} and its firewall file are gone."
