#!/usr/bin/env bash
# container-setup.sh -- runs INSIDE the new container (pushed + started by
# install.sh through `pct exec`). Debian 12. Usage: container-setup.sh <env-file>
#
# The Proxmox host firewall (/etc/pve/firewall/<VMID>.fw) is the real wall.
# Everything here is defence in depth: a hardened service, no extra listeners,
# IPv6 off, a second egress filter, root locked.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C

ENV_FILE=${1:-/root/ytserver-setup.env}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)     # <staging>/proxmox
STAGE=$(dirname "$HERE")                               # <staging> = repo root
# shellcheck disable=SC1090
. "$ENV_FILE"
: "${YTS_GW:?}" "${YTS_ALLOWED:?}" "${YTS_HOST_IPS:?}" "${REPO_OWNER:?}" "${REPO_NAME:?}" "${REPO_BRANCH:?}"
PORT=${YTS_PORT:-8080}
EGRESS_PORTS=${YTS_EGRESS_PORTS:-80,443}
DISK_GB=${YTS_DISK_GB:-8}
DHCP=${YTS_DHCP:-0}

# Pinned deno (V8 runtime yt-dlp needs for YouTube's JS challenges). Bump both
# lines together; hashes are from the official release assets.
DENO_VERSION=2.9.8
DENO_SHA256_x86_64=e890975bc2549807bbcc0b584ffafda72cc7c93349dd99c80483dd784f6c4609
DENO_SHA256_aarch64=d49596c20b9788cf8f5d8ddf644103d4bde56ed239753f0bdb92ba9361d51905

say() { printf '  \033[1;36m->\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m/!\033[0m %s\n' "$*" >&2; }
die() { printf '  \033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f $STAGE/server/requirements.txt ]] || die "no server/requirements.txt in the pushed source"

# ---------------------------------------------------------------- packages
say "apt update + full-upgrade"
apt-get update -qq || die "apt-get update failed (DNS or egress?)"
apt-get full-upgrade -y -qq -o Dpkg::Options::=--force-confold >/dev/null
say "installing packages"
apt-get install -y -qq --no-install-recommends \
    python3 python3-venv ffmpeg ca-certificates curl unzip nftables unattended-upgrades >/dev/null

# ---------------------------------------------------------------- deno
case $(uname -m) in
    x86_64) DENO_ARCH=x86_64; DENO_SHA=$DENO_SHA256_x86_64 ;;
    aarch64) DENO_ARCH=aarch64; DENO_SHA=$DENO_SHA256_aarch64 ;;
    *) die "unsupported architecture $(uname -m)" ;;
esac
say "installing deno ${DENO_VERSION} (${DENO_ARCH}, sha256-pinned)"
TMP=$(mktemp -d)
curl -fsSL --proto '=https' --tlsv1.2 -o "$TMP/deno.zip" \
    "https://github.com/denoland/deno/releases/download/v${DENO_VERSION}/deno-${DENO_ARCH}-unknown-linux-gnu.zip"
echo "${DENO_SHA}  $TMP/deno.zip" | sha256sum -c - >/dev/null || die "deno checksum mismatch -- refusing to install"
unzip -qo "$TMP/deno.zip" deno -d "$TMP"
install -m 0755 -o root -g root "$TMP/deno" /usr/local/bin/deno
rm -rf "$TMP"
deno --version | head -1

# ---------------------------------------------------------------- user + dirs
say "creating service user ytserver (no login, no home)"
getent passwd ytserver >/dev/null || \
    useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin ytserver
install -d -m 0700 -o ytserver -g ytserver /var/cache/ytserver
install -d -m 0755 -o root -g root /etc/ytserver

# ---------------------------------------------------------------- code + venv
say "installing server/ to /opt/ytserver with a venv"
rm -rf /opt/ytserver
install -d -m 0755 /opt/ytserver
cp -a "$STAGE/server/." /opt/ytserver/
python3 -m venv /opt/ytserver/venv
/opt/ytserver/venv/bin/python -m pip install -q --no-cache-dir --disable-pip-version-check \
    -r /opt/ytserver/requirements.txt
/opt/ytserver/venv/bin/python -m pip install -q --no-cache-dir --disable-pip-version-check \
    --upgrade "yt-dlp[default]"
chown -R root:root /opt/ytserver
chmod -R go-w /opt/ytserver
echo "build-initial" > /opt/ytserver/.build-id     # first updater run replaces it
say "yt-dlp $(/opt/ytserver/venv/bin/python -m pip show yt-dlp | sed -n 's/^Version: //p')"

CACHE_MB=$(( DISK_GB * 384 ))                       # ~37% of the disk
(( CACHE_MB > 4096 )) && CACHE_MB=4096
cat > /etc/ytserver/ytserver.env <<EOF
YTS_BIND=0.0.0.0
YTS_PORT=${PORT}
YTS_CACHE_DIR=/var/cache/ytserver
YTS_CACHE_MAX_MB=${CACHE_MB}
YTS_MAX_HEIGHT=360
EOF
cat > /etc/ytserver/update.env <<EOF
REPO_OWNER=${REPO_OWNER}
REPO_NAME=${REPO_NAME}
REPO_BRANCH=${REPO_BRANCH}
# Real search used by the updater self-test (GData v2 videos feed).
SELFTEST_PATH='${YTS_SELFTEST_PATH:-/feeds/api/videos?q=music&max-results=1&v=2}'
EOF
chmod 0644 /etc/ytserver/*.env

# ---------------------------------------------------------------- IPv6 off
say "disabling IPv6 (sysctl)"
cat > /etc/sysctl.d/99-ytserver.conf <<'EOF'
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
say "writing the in-container egress filter (defence in depth)"
ALLOWED_NFT=${YTS_ALLOWED//,/, }
HOSTS_NFT=${YTS_HOST_IPS//,/, }
PORTS_NFT=${EGRESS_PORTS//,/, }
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
table inet ytfw
delete table inet ytfw
table inet ytfw {
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
        ip daddr ${YTS_GW} udp dport 53 accept
        ip daddr ${YTS_GW} tcp dport 53 accept
        ip daddr { ${HOSTS_NFT} } drop
        ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10,
                   169.254.0.0/16, 224.0.0.0/4, 240.0.0.0/4 } drop
        tcp dport { ${PORTS_NFT} } accept
    }
}
EOF
chmod 0644 /etc/nftables.conf
if nft -f /etc/nftables.conf 2>/tmp/nft.err; then
    systemctl enable nftables >/dev/null 2>&1 || true
    say "in-container nftables loaded"
else
    warn "in-container nftables NOT loaded: $(cat /tmp/nft.err)"
    warn "continuing: the host firewall is the real wall"
fi
rm -f /tmp/nft.err

# ---------------------------------------------------------------- units
say "installing systemd units"
install -m 0644 "$HERE/files/ytserver.service" /etc/systemd/system/ytserver.service
install -m 0644 "$HERE/files/ytserver-update.service" /etc/systemd/system/ytserver-update.service
install -m 0644 "$HERE/files/ytserver-update.timer" /etc/systemd/system/ytserver-update.timer
install -m 0755 -o root -g root "$HERE/files/ytserver-update.sh" /usr/local/sbin/ytserver-update
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl daemon-reload
systemctl enable --now ytserver.service ytserver-update.timer >/dev/null 2>&1
sleep 2
systemctl is-active --quiet ytserver || { journalctl -u ytserver -n 40 --no-pager >&2; die "ytserver failed to start"; }

# ---------------------------------------------------------------- self-test
say "self-test: /healthz + one real search"
if /usr/local/sbin/ytserver-update --selftest; then
    say "self-test passed"
else
    warn "self-test FAILED (service is up but the search did not answer) -- journalctl -u ytserver"
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
rm -rf "$STAGE" /root/ytserver-src.tgz "$ENV_FILE"
say "container setup complete"
