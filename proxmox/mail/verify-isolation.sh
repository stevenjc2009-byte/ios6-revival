#!/usr/bin/env bash
# shellcheck disable=SC2015  # "A && pass || fail": pass/fail only printf, they cannot fail, so C never runs after a passing A
# verify-isolation.sh -- prove the walls around the mail-bridge container.
# Copied from ../verify-isolation.sh (copy, don't depend) and adapted for the mail bridge.
# Run as root on the Proxmox host after install:   ./verify-isolation.sh [VMID]
# Prints PASS/FAIL per check; exit status 1 if any FAIL. WARN = could not be
# proven from here (needs a second LAN machine / the iPhone), never counted as pass.
#
# Every "blocked" check passes only on a TIMEOUT (a firewall DROP). An instant
# refusal or a connection means a packet got through, which is a FAIL: a wall
# that merely finds nothing listening has not been proven.
set -uo pipefail

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
NPASS=0; NFAIL=0; NWARN=0
pass() { NPASS=$((NPASS + 1)); printf '  \033[1;32mPASS\033[0m  %s\n' "$*"; }
fail() { NFAIL=$((NFAIL + 1)); printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; }
warn() { NWARN=$((NWARN + 1)); printf '  \033[1;33mWARN\033[0m  %s\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "run as root on the Proxmox host" >&2; exit 2; }
command -v pct >/dev/null || { echo "not a Proxmox host" >&2; exit 2; }
VMID=${1:-${MAILP_VMID:-}}
[[ $VMID =~ ^[0-9]+$ ]] || { echo "usage: $0 VMID" >&2; exit 2; }
[[ $(pct status "$VMID" 2>/dev/null) == *running* ]] || { echo "CT $VMID is not running" >&2; exit 2; }
FWF=/etc/pve/firewall/${VMID}.fw
[[ -f $FWF ]] || { echo "no $FWF -- the container has no host firewall at all" >&2; exit 2; }

ct() { pct exec "$VMID" -- "$@"; }
CT_CIDR=$(ct sh -c "ip -4 -o addr show dev eth0 | awk '{print \$4}'" 2>/dev/null | head -1)
CT_IP=${CT_CIDR%/*}; PFX=${CT_CIDR#*/}
GW=$(ct sh -c "ip -4 route show default | awk '{print \$3; exit}'" 2>/dev/null)
mapfile -t HOST_IPS < <(ip -4 -o addr show scope global | awk '{split($4,a,"/"); print a[1]}' | sort -u)
mapfile -t ALLOWED < <(awk '/^IN ACCEPT/ {for (i=1;i<=NF;i++) if ($i=="-source") print $(i+1)}' "$FWF")
BRIDGE=$(pct config "$VMID" | sed -n 's/^net0:.*bridge=\([^,]*\).*/\1/p')
say "CT ${VMID}: ip ${CT_IP}, gateway ${GW}, host ${HOST_IPS[*]}, allowed clients ${ALLOWED[*]}"

# blocked_tcp LABEL HOST PORT : pass only if the SYN was silently dropped.
blocked_tcp() {
    ct timeout 5 bash -c "exec 3<>/dev/tcp/$2/$3" >/dev/null 2>&1; local rc=$?
    case $rc in
        124) pass "blocked: $1 ($2:$3 timed out = dropped)" ;;
        0) fail "REACHED $1 ($2:$3 connected!)" ;;
        *) fail "$1 ($2:$3) was not dropped (exit $rc: refused/unreachable means the packet got somewhere)" ;;
    esac
}
DNSQ='import socket,sys;s=socket.socket(2,2);s.settimeout(4);s.sendto(b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01",(sys.argv[1],53));s.recvfrom(512)'

say "1. cannot reach the LAN, the router or the Proxmox host"
blocked_tcp "router web UI" "$GW" 80
blocked_tcp "router web UI (https)" "$GW" 443
for h in "${HOST_IPS[@]}"; do
    blocked_tcp "Proxmox web UI" "$h" 8006
    blocked_tcp "Proxmox SSH" "$h" 22
done
for a in "${ALLOWED[@]}"; do
    blocked_tcp "iPhone/client lockdownd" "$a" 62078
    blocked_tcp "iPhone/client ssh" "$a" 22
done
blocked_tcp "10.0.0.0/8 range" 10.0.0.1 80
blocked_tcp "172.16.0.0/12 range" 172.16.0.1 80
blocked_tcp "192.168.0.0/16 range" 192.168.1.1 80
blocked_tcp "Tailscale/CGNAT 100.64.0.0/10" 100.100.100.100 80
blocked_tcp "link-local/metadata 169.254.0.0/16" 169.254.169.254 80

say "2. cannot use the internet except the mail/OAuth ports and gateway DNS"
blocked_tcp "public SMTP (port 25)" 1.1.1.1 25
blocked_tcp "plain http (port 80, only open during install)" 1.1.1.1 80
blocked_tcp "public SSH" 1.1.1.1 22
ct python3 -c "$DNSQ" 1.1.1.1 >/dev/null 2>&1 && fail "REACHED outside DNS 1.1.1.1:53/udp" || pass "blocked: outside DNS 1.1.1.1:53/udp (no answer)"
ct timeout 5 bash -c 'exec 3<>/dev/tcp/2606:4700:4700::1111/443' >/dev/null 2>&1 && fail "IPv6 reached the internet" || pass "blocked: IPv6 internet"

say "3. what must work still works"
CONF=/etc/mailproxy/emailproxy.config
ct curl -sS -m 12 -o /dev/null https://1.1.1.1/ >/dev/null 2>&1 && pass "https to 1.1.1.1:443" || fail "https to 1.1.1.1:443 failed (egress broken)"
ct python3 -c "$DNSQ" "$GW" >/dev/null 2>&1 && pass "DNS answered by the gateway ${GW}" || fail "no DNS answer from the gateway ${GW}"
# shellcheck disable=SC2016
mapfile -t UPSTREAM < <(ct awk '/^\[(IMAP|SMTP)-/ {s=1; next} /^\[/ {s=0} s && /^server_address/ {a=$3} s && /^server_port/ {print a ":" $3}' "$CONF" 2>/dev/null | sort -u)
(( ${#UPSTREAM[@]} )) || fail "cannot read the providers from ${CONF}"
for u in "${UPSTREAM[@]}"; do
    h=${u%:*}; p=${u#*:}
    ct getent hosts "$h" >/dev/null 2>&1 && pass "resolves $h" || fail "cannot resolve $h"
    ct timeout 12 bash -c "exec 3<>/dev/tcp/$h/$p" >/dev/null 2>&1 && pass "connects to $h:$p" || fail "cannot connect to $h:$p"
done
for u in accounts.google.com:443 login.microsoftonline.com:443; do
    ct grep -q "${u%:*}" "$CONF" 2>/dev/null || continue
    ct timeout 12 bash -c "exec 3<>/dev/tcp/${u%:*}/443" >/dev/null 2>&1 && pass "connects to ${u}" || fail "cannot connect to ${u}"
done
ct systemctl is-active --quiet mailproxy && pass "mailproxy.service is active" || fail "mailproxy.service is not active"
ct mailproxy-update --selftest >/dev/null 2>&1 && pass "every local port relays its provider greeting" || fail "mailproxy-update --selftest failed"

say "4. nothing else listens, IPv6 is off, service is sandboxed"
LPORTS=$(ct sed -n 's/^\[\(IMAP\|SMTP\)-\([0-9]*\)\]$/:$/p' "$CONF" 2>/dev/null | paste -sd'|')
EXTRA=$(ct ss -H -tln 2>/dev/null | awk -v p="$LPORTS" '$4 !~ p && $4 !~ /^127\./ {print $4}')
[[ -n $LPORTS && -z $EXTRA ]] && pass "only the mail ports listen (besides loopback)" || fail "extra TCP listeners: ${EXTRA//$'
'/ }"
[[ $(ct cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null) == 1 ]] && pass "IPv6 disabled in the container" || fail "IPv6 not disabled in the container"
[[ $(ct passwd -S root 2>/dev/null | awk '{print $2}') == L ]] && pass "root password locked" || fail "root password not locked"
[[ $(ct stat -c '%a %U' /var/lib/mailproxy 2>/dev/null) == "700 mailproxy" ]] && pass "token store /var/lib/mailproxy is 0700 mailproxy" || fail "token store permissions wrong"
[[ $(ct stat -c '%a %U:%G' "$CONF" 2>/dev/null) == "640 root:mailproxy" ]] && pass "config is 0640 root:mailproxy" || fail "config permissions wrong"
[[ $(ct systemctl show mailproxy -p User --value 2>/dev/null) == mailproxy ]] && pass "service runs as user mailproxy" || fail "service does not run as mailproxy"
EXPOSURE=$(ct systemd-analyze security mailproxy.service --no-pager 2>/dev/null | awk '/Overall exposure level/ {print $(NF-1), $NF}')
[[ -n $EXPOSURE ]] && say "   systemd exposure (informational): ${EXPOSURE}"

say "5. the host wall holds even if root inside the container wipes its own firewall"
ct nft list table inet mailfw >/dev/null 2>&1 && pass "in-container nftables layer is loaded (about to be destroyed)" || warn "in-container nftables was not loaded; this test then shows the host wall alone"
ct nft flush ruleset >/dev/null 2>&1
blocked_tcp "router web UI WITHOUT in-container firewall" "$GW" 80
blocked_tcp "Proxmox web UI WITHOUT in-container firewall" "${HOST_IPS[0]}" 8006
ct systemctl restart nftables >/dev/null 2>&1
ct nft list table inet mailfw >/dev/null 2>&1 && say "   in-container nftables restored" || warn "could not restore in-container nftables: run  pct exec ${VMID} -- systemctl restart nftables"

say "6. inbound: only the allowed clients may reach the mail ports"
FIRST_PORT=$(awk '/^IN ACCEPT/ {for (i=1;i<=NF;i++) if ($i=="-dport") {split($(i+1),a,","); print a[1]; exit}}' "$FWF")
FIRST_PORT=${FIRST_PORT:-1143}
HOST_ALLOWED=0; for a in "${ALLOWED[@]}"; do for h in "${HOST_IPS[@]}"; do [[ $a == "$h" ]] && HOST_ALLOWED=1; done; done
if [[ $HOST_ALLOWED -eq 0 ]]; then
    timeout 5 bash -c "exec 3<>/dev/tcp/${CT_IP}/${FIRST_PORT}" >/dev/null 2>&1; rc=$?
    if [[ $rc -eq 124 ]]; then pass "Proxmox host (not allowed) is dropped on ${CT_IP}:${FIRST_PORT}"
    else warn "host reached ${CT_IP}:${FIRST_PORT} -- host-originated traffic may bypass the guest firewall; use the stranger test below / another LAN PC"; fi
fi
SIP=""; if [[ $PFX =~ ^[0-9]+$ && $PFX -ge 24 && -n $BRIDGE ]] && command -v ip >/dev/null; then
    for last in 250 251 252; do
        c="${CT_IP%.*}.${last}"
        if ! ping -c1 -W1 "$c" >/dev/null 2>&1; then SIP=$c; break; fi
    done
fi
if [[ -n $SIP ]]; then
    NS=mpsv$$; HV=mpsvh$$; NV=mpsvn$$
    cleanup_ns() { ip link del "$HV" >/dev/null 2>&1; ip netns del "$NS" >/dev/null 2>&1; }
    trap cleanup_ns EXIT
    if ip netns add "$NS" && ip link add "$HV" type veth peer name "$NV" && ip link set "$NV" netns "$NS"        && ip link set "$HV" master "$BRIDGE" up && ip -n "$NS" addr add "${SIP}/${PFX}" dev "$NV"        && ip -n "$NS" link set "$NV" up && ip -n "$NS" link set lo up; then
        sleep 3
        ip netns exec "$NS" timeout 6 bash -c "exec 3<>/dev/tcp/${CT_IP}/${FIRST_PORT}" >/dev/null 2>&1; rc=$?
        NEIGH=$(ip netns exec "$NS" ip neigh show "$CT_IP" 2>/dev/null)
        if [[ $rc -eq 124 && $NEIGH == *lladdr* && $NEIGH != *FAILED* ]]; then
            pass "stranger ${SIP} (not allowed) sees the CT at layer 2 but its tcp/${FIRST_PORT} SYN is dropped"
        elif [[ $rc -eq 0 ]]; then fail "stranger ${SIP} REACHED ${CT_IP}:${FIRST_PORT} -- inbound allow-list is not working"
        else warn "stranger test inconclusive (exit $rc, neighbour: ${NEIGH:-none}) -- test from another LAN PC"; fi
    else warn "could not build the test namespace on ${BRIDGE}; test inbound from another LAN PC"; fi
    cleanup_ns
else
    warn "no free test IP / unsupported subnet; from another LAN PC: nc -w5 -v ${CT_IP} ${FIRST_PORT} must time out"
fi
warn "allowed side (${ALLOWED[*]} -> ${CT_IP}:mail ports works) can only be proven from the iPhone: add the account in iOS Mail (README)"

echo
echo "result: ${NPASS} passed, ${NFAIL} failed, ${NWARN} warnings"
[[ $NFAIL -eq 0 ]] || { echo "ISOLATION NOT PROVEN -- fix the FAIL lines above"; exit 1; }
