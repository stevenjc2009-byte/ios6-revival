#!/usr/bin/env bash
# fw.sh -- sourced by install-main.sh. Proxmox firewall pieces: the per-guest
# <VMID>.fw file, the datacenter switch, and a check that rules went live.
# (A copy of the YouTube installer's fw.sh, adapted; the two are independent.)
# Expects: VMID CT_IP GW DHCP PORT ALLOWED[] HOST_IPS[] EGRESS_PORTS DRY_RUN
#          and the say/warn/die/confirm_yes helpers from install-main.sh.

FW_DIR=${WXS_FW_DIR:-/etc/pve/firewall}
CLUSTER_FW="$FW_DIR/cluster.fw"

# Policy choice: policy_out DROP plus explicit accepts (fail closed). A mistake
# or a missing rule blocks traffic instead of opening it. Because "the internet
# but not the LAN" cannot be an accept rule, the private ranges are dropped
# first and the internet accept (tcp 443; 80,443 only if apt could not use
# https during install) comes last. First match wins
# in PVE, so the gateway-DNS accepts MUST stay above the 192.168/16 drop.
fw_render() {
    local c h
    cat <<EOF
# ios6-revival weather server (CT ${VMID}) -- written by proxmox/weather/install.sh
# Enforced by the Proxmox host; root inside the container cannot change it.
# Rules are first-match-wins. To change who may connect, edit the IN ACCEPT
# lines (and the ipset if the container IP changes); pve-firewall reloads in ~10 s.
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: DROP
ipfilter: 1
macfilter: 1
dhcp: ${DHCP}
ndp: 0
radv: 0
log_level_in: nolog
log_level_out: nolog

EOF
    if [[ -n ${CT_IP:-} ]]; then
        printf '[IPSET ipfilter-net0]\n%s\n\n' "$CT_IP"
    fi
    echo "[RULES]"
    for c in "${ALLOWED[@]}"; do
        echo "IN ACCEPT -source ${c} -p tcp -dport ${PORT} # allowed client (iPhone)"
    done
    cat <<EOF
OUT ACCEPT -dest ${GW} -p udp -dport 53 # DNS via the gateway only
OUT ACCEPT -dest ${GW} -p tcp -dport 53 # DNS over TCP via the gateway only
EOF
    for h in "${HOST_IPS[@]}"; do
        echo "OUT DROP -dest ${h} # the Proxmox host itself (web UI :8006, SSH)"
    done
    cat <<EOF
OUT DROP -dest 10.0.0.0/8 # private LAN
OUT DROP -dest 172.16.0.0/12 # private LAN
OUT DROP -dest 192.168.0.0/16 # private LAN (router, iPhone, PCs)
OUT DROP -dest 100.64.0.0/10 # CGNAT / Tailscale
OUT DROP -dest 169.254.0.0/16 # link-local
OUT DROP -dest 224.0.0.0/4 # multicast
OUT DROP -dest 240.0.0.0/4 # reserved
OUT ACCEPT -dest 0.0.0.0/1,128.0.0.0/1 -p tcp -dport ${EGRESS_PORTS} # internet, HTTPS to data providers only; two IPv4 halves so the rule is never applied to IPv6
EOF
}

fw_write() {
    local f="$FW_DIR/${VMID}.fw"
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "---- would write $f ----"; fw_render; echo "---- end ----"; return 0
    fi
    install -d "$FW_DIR"
    [[ -f $f ]] && cp -a "$f" "/root/${VMID}.fw.bak.$(date +%s)"
    fw_render > "$f"
    say "wrote $f"
}

# Datacenter firewall must be ON for any guest .fw to take effect. Host and
# existing guests stay unaffected: policy_in/out ACCEPT at datacenter level, and
# host.fw is never touched.
cluster_fw_ensure() {
    local en pin tmp
    if [[ -f $CLUSTER_FW ]]; then
        en=$(awk '/^\[/{s=($0=="[OPTIONS]")} s&&/^enable:/{print $2}' "$CLUSTER_FW" | tail -1)
        pin=$(awk '/^\[/{s=($0=="[OPTIONS]")} s&&/^policy_in:/{print $2}' "$CLUSTER_FW" | tail -1)
        if [[ $en == 1 ]]; then
            say "datacenter firewall already enabled -- $CLUSTER_FW left untouched"
            [[ -z $pin || $pin == ACCEPT ]] || warn "your datacenter policy_in is $pin (your own rules); not changed"
            return 0
        fi
        [[ -z $pin || $pin == ACCEPT ]] || \
            die "$CLUSTER_FW is disabled but sets policy_in: $pin. Enabling it could lock you out of the web UI/SSH; enable it yourself (Datacenter > Firewall > Options) after checking your rules, then re-run."
    fi
    cat <<EOF

 DATACENTER FIREWALL CHANGE (needed: guest firewalls only work when it is on)
   file    : $CLUSTER_FW  ($( [[ -f $CLUSTER_FW ]] && echo "exists, enable is off/missing" || echo "does not exist" ))
   change  : [OPTIONS] enable: 1, policy_in: ACCEPT, policy_out: ACCEPT
   effect  : the Proxmox host and all other guests keep accepting everything, exactly as now.
             Only guests with their own enabled .fw (this container) get filtered.
   untouched: host.fw and every other guest's .fw.  Backup of the old file: /root/cluster.fw.bak.*
EOF
    if [[ $DRY_RUN -eq 1 ]]; then echo " (dry run: nothing changed)"; return 0; fi
    confirm_yes "WXS_ACCEPT_CLUSTER_FW"
    install -d "$FW_DIR"
    tmp=$(mktemp)
    if [[ -f $CLUSTER_FW ]]; then
        cp -a "$CLUSTER_FW" "/root/cluster.fw.bak.$(date +%s)"
        cp "$CLUSTER_FW" "$tmp"
        grep -q '^\[OPTIONS\]' "$tmp" || { printf '[OPTIONS]\n\n' | cat - "$tmp" > "$tmp.n"; mv "$tmp.n" "$tmp"; }
        if grep -q '^enable:' "$tmp"; then sed -i 's/^enable:.*/enable: 1/' "$tmp"
        else sed -i '/^\[OPTIONS\]/a enable: 1' "$tmp"; fi
        grep -q '^policy_in:' "$tmp" || sed -i '/^\[OPTIONS\]/a policy_in: ACCEPT' "$tmp"
        grep -q '^policy_out:' "$tmp" || sed -i '/^\[OPTIONS\]/a policy_out: ACCEPT' "$tmp"
    else
        printf '[OPTIONS]\nenable: 1\npolicy_in: ACCEPT\npolicy_out: ACCEPT\n' > "$tmp"
    fi
    cat "$tmp" > "$CLUSTER_FW"      # pmxcfs: write in place, no rename
    rm -f "$tmp"
    say "datacenter firewall enabled ($CLUSTER_FW)"
}

# Docker on the host sets the iptables FORWARD policy to DROP. pve-firewall marks
# allowed guest packets and returns, relying on policy ACCEPT, so with Docker
# every firewalled guest (this one included) loses its network. One rule appended
# after Docker's and PVE's chains accepts bridged frames neither of them dropped;
# routed (Docker) traffic is untouched. A oneshot unit re-adds it at boot.
FWD_UNIT=${WXS_FWD_UNIT:-/etc/systemd/system/vmbr0-forward.service}
FWD_RULE=(FORWARD -m physdev --physdev-is-bridged -j ACCEPT)
host_forward_ensure() {
    iptables -S FORWARD 2>/dev/null | grep -x -- '-P FORWARD DROP' >/dev/null || return 0
    if iptables -C "${FWD_RULE[@]}" 2>/dev/null && [[ -f $FWD_UNIT ]]; then
        say "host FORWARD policy is DROP (Docker) -- bridged-traffic rule already in place"; return 0
    fi
    cat <<EOF

 HOST FORWARD CHANGE (needed: Docker on this host drops forwarded traffic)
   found   : iptables FORWARD policy DROP (Docker sets this)
   change  : iptables -A ${FWD_RULE[*]}
             plus $FWD_UNIT to re-add it at boot
   effect  : bridged guest traffic that the Proxmox and Docker rules allow gets through again.
             Without it this container (and any other firewalled guest) has no network.
   untouched: Docker's own chains, routed traffic, every .fw file.
EOF
    if [[ $DRY_RUN -eq 1 ]]; then echo " (dry run: nothing changed)"; return 0; fi
    confirm_yes "WXS_ACCEPT_HOST_FORWARD"
    iptables -C "${FWD_RULE[@]}" 2>/dev/null || iptables -A "${FWD_RULE[@]}"
    cat > "$FWD_UNIT" <<EOF
[Unit]
Description=Let bridged guest traffic past Docker's FORWARD DROP policy (ios6-revival installer)
After=docker.service pve-firewall.service
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'iptables -C ${FWD_RULE[*]} 2>/dev/null || iptables -A ${FWD_RULE[*]}'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$(basename "$FWD_UNIT")" >/dev/null 2>&1
    say "bridged-traffic rule added; $FWD_UNIT keeps it after reboot"
}

# Host uses the nftables backend (proxmox-firewall) when host.fw sets "nftables: 1".
fw_nft_backend() {
    awk '/^\[/{s=($0=="[OPTIONS]")} s&&/^nftables:/{print $2}' "${WXS_HOST_FW:-/etc/pve/local/host.fw}" 2>/dev/null | grep '^1$' >/dev/null
}

# iptables backend names guest chains after the veth (veth109i0-IN); the
# nftables backend names them guest-109-in / guest-109-out.
fw_applied() {
    local pat="veth${VMID}i0|guest-${VMID}-(in|out)"
    iptables-save 2>/dev/null | grep -E "$pat" >/dev/null && return 0
    command -v iptables-legacy-save >/dev/null && iptables-legacy-save 2>/dev/null | grep -E "$pat" >/dev/null && return 0
    nft list ruleset 2>/dev/null | grep -E "$pat" >/dev/null && return 0
    return 1
}

fw_wait_applied() {
    local svc=pve-firewall
    fw_nft_backend && svc=proxmox-firewall
    systemctl is-active --quiet "$svc" || { warn "$svc not running; starting it"; systemctl enable --now "$svc"; }
    for _ in $(seq 1 45); do fw_applied && return 0; sleep 2; done
    return 1
}

# Printed when the rules never show up, so the next report has the evidence.
fw_diagnose() {
    echo "---- firewall diagnostics (send this whole block) ----"
    pve-firewall status 2>&1
    echo "backend: $(fw_nft_backend && echo nftables || echo iptables); pve-firewall $(systemctl is-active pve-firewall); proxmox-firewall $(systemctl is-active proxmox-firewall 2>/dev/null)"
    pct config "$VMID" 2>&1 | grep -E '^(net0|features|unprivileged):'
    ip -br link 2>/dev/null | grep -E "(veth|fwbr|fwpr|fwln)${VMID}" || echo "no ${VMID} interfaces on the host"
    echo "iptables lines: $(iptables-save 2>/dev/null | grep -c "${VMID}i0")  nft lines: $(nft list ruleset 2>/dev/null | grep -cE "${VMID}i0|guest-${VMID}-")"
    pve-firewall compile 2>&1 | grep -iE "error|warn|unable|parse|illegal|${VMID}\.fw" | sed -n 1,20p
    journalctl -u pve-firewall -u proxmox-firewall -n 15 --no-pager 2>&1
    echo "---- end ----"
}
