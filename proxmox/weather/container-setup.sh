#!/usr/bin/env bash
# container-setup.sh -- runs INSIDE the new container (pushed + started by
# install-main.sh through `pct exec`). Debian 12. Usage: container-setup.sh <env-file>
#
# The Proxmox host firewall (/etc/pve/firewall/<VMID>.fw) is the real wall.
# Everything here is defence in depth: a hardened service, no extra listeners,
# IPv6 off, a second egress filter, root locked.
#
# Test hook (never set by the installer): WXS_SKIP_NFT_LOAD=1 writes
# /etc/nftables.conf but does not load it, so a rehearsal outside a container
# cannot cut its own network.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin  # pct exec passes no /usr/local/bin

ENV_FILE=${1:-/root/wxserver-setup.env}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)     # <staging>/proxmox/weather
STAGE=$(cd "$HERE/../.." && pwd)                       # <staging> = repo root
# shellcheck disable=SC1090
. "$ENV_FILE"
: "${WXS_GW:?}" "${WXS_ALLOWED:?}" "${WXS_HOST_IPS:?}"
PORT=${WXS_PORT:-8000}
EGRESS_PORTS=${WXS_EGRESS_PORTS:-80,443}
DHCP=${WXS_DHCP:-0}

# The server code: TestOrig/YQL-X-Server-New (GPL-3), pinned to one commit and
# checked against a hash of the whole extracted tree (a tarball's own sha256 is
# not stable across gzip versions, the tree is). Bump both lines together after
# reading the diff.
UP_REPO=TestOrig/YQL-X-Server-New
UP_COMMIT=f236e98a3f4a4d4f855933ca5ad4decae78eeb83
UP_TREE_SHA256=3c361c99cbf90529bfa6f96b40f33d572c6bd5153cbfeae7515adaf3c49461c6

say() { printf '  \033[1;36m->\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m/!\033[0m %s\n' "$*" >&2; }
die() { printf '  \033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f $HERE/files/requirements.txt && -d $HERE/files/overlay ]] || die "the pushed source is incomplete (files/requirements.txt or files/overlay missing)"

# ---------------------------------------------------------------- packages
# The template ships apt on plain http and without ca-certificates. Update once
# over http, install ca-certificates, then move apt to https so the firewall
# only needs tcp 443 (the host rewrites the rules to 443 only when this worked).
say "apt update (http, first run) + ca-certificates"
apt-get update -qq --error-on=any || die "apt-get update failed (DNS or egress?)"
apt-get install -y -qq --no-install-recommends ca-certificates >/dev/null

EGRESS_FINAL=$EGRESS_PORTS
mkdir -p /root/apt-sources.orig
APT_FILES=()
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*; do
    [[ -f $f ]] || continue
    APT_FILES+=("$f"); cp -a "$f" "/root/apt-sources.orig/$(basename "$f")"
    sed -i 's|http://deb\.debian\.org|https://deb.debian.org|g; s|http://security\.debian\.org|https://security.debian.org|g' "$f"
done
if apt-get update -qq --error-on=any 2>/dev/null; then
    if grep -hE '^(deb |URIs:)' "${APT_FILES[@]}" 2>/dev/null | grep -q 'http://'; then
        warn "apt still has a plain-http source; the firewall keeps tcp 80 open"
    else
        EGRESS_FINAL=443
        say "apt now uses https only"
    fi
else
    [[ $EGRESS_PORTS != 443 ]] || die "apt over https failed and the firewall allows only tcp 443"
    for f in "${APT_FILES[@]}"; do cp -a "/root/apt-sources.orig/$(basename "$f")" "$f"; done
    apt-get update -qq --error-on=any || die "apt-get update failed after restoring http sources"
    warn "apt over https failed; using http, so the firewall keeps tcp 80 open (egress ${EGRESS_PORTS})"
fi
echo "$EGRESS_FINAL" > /root/.wxs-egress       # read (and removed) by install-main.sh

say "apt full-upgrade"
apt-get full-upgrade -y -qq -o Dpkg::Options::=--force-confold >/dev/null
say "installing packages"
apt-get install -y -qq --no-install-recommends \
    python3 python3-venv curl nftables iproute2 unattended-upgrades >/dev/null
python3 -c 'import sys; sys.exit(0 if sys.version_info[:2] == (3, 11) else 1)' \
    || die "requirements.txt is pinned for Python 3.11 (Debian 12); this is $(python3 -V)"

# ---------------------------------------------------------------- user + dirs
say "creating service user wxserver (no login, no home)"
getent passwd wxserver >/dev/null || \
    useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin wxserver
install -d -m 0755 -o root -g root /etc/wxserver

# ---------------------------------------------------------------- server code
say "fetching ${UP_REPO}@${UP_COMMIT:0:12}"
UPTMP=$(mktemp -d)
curl -fsSL --proto '=https' --tlsv1.2 -m 180 -o "$UPTMP/up.tgz" \
    "https://codeload.github.com/${UP_REPO}/tar.gz/${UP_COMMIT}"
mkdir "$UPTMP/up"
tar -xzf "$UPTMP/up.tgz" --no-same-owner -C "$UPTMP/up" --strip-components=1
TREE=$(cd "$UPTMP/up" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum -b | sha256sum | cut -d' ' -f1)
[[ $TREE == "$UP_TREE_SHA256" ]] || die "upstream tree hash mismatch (got ${TREE}, expected ${UP_TREE_SHA256}) -- refusing to install"
say "upstream tree hash matches the pin"
python3 "$HERE/files/apply_overlay.py" "$UPTMP/up" "$HERE/files/overlay"

say "installing to /opt/wxserver with a venv (wheels only, no compiler)"
rm -rf /opt/wxserver
install -d -m 0755 /opt/wxserver
cp -a "$UPTMP/up/yql_x_server" /opt/wxserver/yql_x_server
cp "$UPTMP/up/LICENSE" /opt/wxserver/LICENSE
cp "$HERE/files/probe.py" "$HERE/files/requirements.txt" /opt/wxserver/
rm -rf "$UPTMP"
python3 -m venv /opt/wxserver/venv
PIP=(/opt/wxserver/venv/bin/python -m pip)
"${PIP[@]}" install -q --no-cache-dir --disable-pip-version-check --only-binary=:all: \
    -r /opt/wxserver/requirements.txt
"${PIP[@]}" check >/dev/null || die "pip check found conflicting packages"
"${PIP[@]}" freeze | sha256sum | cut -d' ' -f1 > /opt/wxserver/.build-id
chown -R root:root /opt/wxserver
chmod -R go-w /opt/wxserver
say "yfinance $("${PIP[@]}" show yfinance | sed -n 's/^Version: //p')"

cat > /etc/wxserver/wxserver.env <<EOF
WXS_BIND=0.0.0.0
WXS_PORT=${PORT}
EOF
chmod 0644 /etc/wxserver/wxserver.env

# ---------------------------------------------------------------- IPv6 off
say "disabling IPv6 (sysctl)"
cat > /etc/sysctl.d/99-wxserver.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
-net.ipv4.conf.all.accept_redirects = 0
-net.ipv4.conf.all.send_redirects = 0
-net.ipv4.conf.all.accept_source_route = 0
EOF
sysctl --system >/dev/null 2>&1 || true
[[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null) == 1 ]] || \
    warn "IPv6 still enabled (sysctl write refused?) -- the host firewall still drops all IPv6"

# ---------------------------------------------------------------- remove listeners
say "removing sshd, mail and other network daemons"
PURGE=()
for p in openssh-server openssh-sftp-server postfix exim4-base exim4-daemon-light rpcbind nfs-common avahi-daemon samba-common; do
    dpkg -s "$p" >/dev/null 2>&1 && PURGE+=("$p")
done
(( ${#PURGE[@]} == 0 )) || apt-get purge -y -qq "${PURGE[@]}" >/dev/null
systemctl mask ssh.service ssh.socket sshd.service >/dev/null 2>&1 || true
apt-get autoremove --purge -y -qq >/dev/null
apt-get clean

# ---------------------------------------------------------------- nftables (second layer)
say "writing the in-container egress filter (defence in depth, tcp ${EGRESS_FINAL})"
ALLOWED_NFT=${WXS_ALLOWED//,/, }
HOSTS_NFT=${WXS_HOST_IPS//,/, }
PORTS_NFT=${EGRESS_FINAL//,/, }
DHCP_IN="" DHCP_OUT=""
if [[ $DHCP == 1 ]]; then
    DHCP_IN="udp sport 67 udp dport 68 accept"
    DHCP_OUT="udp sport 68 udp dport 67 accept"
fi
cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
# Managed by container-setup.sh. DEFENCE IN DEPTH ONLY: root inside this
# container can flush this ruleset. The real wall is the Proxmox host firewall
# (/etc/pve/firewall/<VMID>.fw), which the guest cannot change.
table inet wxfw
delete table inet wxfw
table inet wxfw {
    chain input {
        type filter hook input priority filter; policy drop;
        iifname "lo" accept
        ct state established,related accept
        ct state invalid drop
        ${DHCP_IN}
        ip saddr { ${ALLOWED_NFT} } tcp dport ${PORT} accept
    }
    chain forward {
        type filter hook forward priority filter; policy drop;
    }
    chain output {
        type filter hook output priority filter; policy drop;
        oifname "lo" accept
        ct state established,related accept
        ct state invalid drop
        meta nfproto ipv6 drop
        ${DHCP_OUT}
        ip daddr ${WXS_GW} udp dport 53 accept
        ip daddr ${WXS_GW} tcp dport 53 accept
        ip daddr { ${HOSTS_NFT} } drop
        ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10,
                   169.254.0.0/16, 224.0.0.0/4, 240.0.0.0/4 } drop
        tcp dport { ${PORTS_NFT} } accept
    }
}
EOF
chmod 0644 /etc/nftables.conf
if [[ ${WXS_SKIP_NFT_LOAD:-0} == 1 ]]; then
    warn "WXS_SKIP_NFT_LOAD=1: ruleset written, NOT loaded (rehearsal only)"
elif nft -f /etc/nftables.conf 2>/tmp/nft.err; then
    systemctl enable nftables >/dev/null 2>&1 || true
    say "in-container nftables loaded"
else
    warn "in-container nftables NOT loaded: $(cat /tmp/nft.err)"
    warn "continuing: the host firewall is the real wall"
fi
rm -f /tmp/nft.err

# ---------------------------------------------------------------- units
say "installing systemd units"
install -m 0644 "$HERE/files/wxserver.service" /etc/systemd/system/wxserver.service
install -m 0644 "$HERE/files/wxserver-update.service" /etc/systemd/system/wxserver-update.service
install -m 0644 "$HERE/files/wxserver-update.timer" /etc/systemd/system/wxserver-update.timer
install -m 0755 -o root -g root "$HERE/files/wxserver-update.sh" /usr/local/sbin/wxserver-update
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl daemon-reload
systemctl enable --now wxserver.service wxserver-update.timer >/dev/null 2>&1
sleep 2
systemctl is-active --quiet wxserver || { journalctl -u wxserver -n 40 --no-pager >&2; die "wxserver failed to start"; }

# ---------------------------------------------------------------- self-test
say "self-test: probe.py (weather search + forecast, stock quote + chart + news)"
if /usr/local/sbin/wxserver-update --selftest; then
    say "self-test passed"
else
    warn "self-test FAILED (service is up but a request did not answer) -- journalctl -u wxserver; /opt/wxserver/venv/bin/python /opt/wxserver/probe.py --base http://127.0.0.1:${PORT}"
fi

# ---------------------------------------------------------------- listeners + root
say "listening sockets (TCP):"
ss -H -tlnp | sed 's/^/     /'
EXTRA=$(ss -H -tln | awk -v p=":${PORT}\$" '$4 !~ p && $4 !~ /^127\./ {print $4}')
[[ -z $EXTRA ]] || die "unexpected TCP listeners: ${EXTRA//$'\n'/ }"
say "listening sockets (UDP, informational):"
ss -H -uln | sed 's/^/     /'
passwd -l root >/dev/null
say "root password locked (admin from the host with: pct enter <VMID>)"
[[ $STAGE != /root/* ]] || rm -rf "$STAGE"       # never delete a checkout the script was run from
rm -f /root/wxserver-src.tgz "$ENV_FILE"
say "container setup complete"
