#!/usr/bin/env bash
# container-setup.sh -- runs INSIDE the new container (pushed + started by install-main.sh through
# `pct exec`). Debian 12. Usage: container-setup.sh <env-file>
# Copied from ../container-setup.sh (copy, don't depend) and adapted for the mail bridge.
#
# The Proxmox host firewall (/etc/pve/firewall/<VMID>.fw) is the real wall. Everything here is
# defence in depth: a hardened service, no extra listeners, IPv6 off, a second egress filter, root locked.
# No pip, no venv: the proxy is one pinned, sha256-checked file; its two libraries come from Debian apt.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

ENV_FILE=${1:-/root/mailproxy-setup.env}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)     # <staging>/proxmox/mail
STAGE=$(dirname "$(dirname "$HERE")")                  # <staging>
# shellcheck disable=SC1090
. "$ENV_FILE"
: "${MAILP_GW:?}" "${MAILP_ALLOWED:?}" "${MAILP_HOST_IPS:?}" "${MAILP_EGRESS_PORTS:?}"
DHCP=${MAILP_DHCP:-0}
LOCAL_TLS=${MAILP_LOCAL_TLS:-0}
CONF=/etc/mailproxy/emailproxy.config

say() { printf '  \033[1;36m->\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m/!\033[0m %s\n' "$*" >&2; }
die() { printf '  \033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f $HERE/files/PIN && -f $HERE/files/mailproxy-update ]] || die "the pushed source has no proxmox/mail/files"

# ---------------------------------------------------------------- packages
say "apt update + full-upgrade (tcp/80 is open only during install)"
apt-get update -qq --error-on=any || die "apt-get update failed (DNS or egress?)"
apt-get full-upgrade -y -qq -o Dpkg::Options::=--force-confold >/dev/null
say "installing packages"
apt-get install -y -qq --no-install-recommends \
    python3 python3-cryptography python3-prompt-toolkit ca-certificates curl openssl nftables unattended-upgrades >/dev/null
# From here on apt uses https only, because the final firewall closes tcp/80.
sed -i 's|http://|https://|g' /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list 2>/dev/null || true
apt-get update -qq --error-on=any || die "apt over https failed after switching the sources"
python3 -c 'import asyncore, cryptography, prompt_toolkit' || die "python3 lacks asyncore/cryptography/prompt_toolkit (the proxy needs Python < 3.12 here)"
say "python $(python3 -c 'import sys;print(sys.version.split()[0])'), cryptography $(python3 -c 'import cryptography;print(cryptography.__version__)')"

# ---------------------------------------------------------------- user + dirs
say "creating service user mailproxy (no login, no home)"
getent passwd mailproxy >/dev/null || \
    useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin mailproxy
install -d -m 0700 -o mailproxy -g mailproxy /var/lib/mailproxy      # the token store (survives restarts and updates)
install -d -m 0750 -o root -g mailproxy /etc/mailproxy
install -d -m 0755 /opt/mailproxy /usr/local/share/mailproxy

# ---------------------------------------------------------------- local TLS (optional)
TLS_LINES=""
if [[ $LOCAL_TLS == 1 ]]; then
    CTIP=${MAILP_CT_IP:-$(ip -4 -o addr show dev eth0 | awk '{print $4}' | cut -d/ -f1 | head -1)}
    say "optional TLS to the phone: self-signed RSA-2048/SHA-256 certificate for ${CTIP}, 10 years"
    install -d -m 0750 -o root -g mailproxy /etc/mailproxy/tls
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 -subj "/CN=${CTIP}" \
        -addext "subjectAltName=IP:${CTIP}" -keyout /etc/mailproxy/tls/key.pem -out /etc/mailproxy/tls/cert.pem 2>/dev/null
    chown root:mailproxy /etc/mailproxy/tls/*.pem; chmod 0640 /etc/mailproxy/tls/key.pem; chmod 0644 /etc/mailproxy/tls/cert.pem
    TLS_LINES=$'local_certificate_path = /etc/mailproxy/tls/cert.pem\nlocal_key_path = /etc/mailproxy/tls/key.pem'
fi

# ---------------------------------------------------------------- config (secrets live only here)
say "writing ${CONF} (root:mailproxy 0640)"
umask 077
emit_server() { # kind port host rport [starttls]
    printf '[%s-%s]\nserver_address = %s\nserver_port = %s\n' "$1" "$2" "$3" "$4"
    [[ -z ${5:-} ]] || printf 'server_starttls = True\n'
    printf 'local_address = 0.0.0.0\n'
    [[ -z $TLS_LINES ]] || printf '%s\n' "$TLS_LINES"
    printf '\n'
}
{
    echo "# Written by container-setup.sh. Proxy docs: https://github.com/simonrob/email-oauth2-proxy"
    echo "# Servers = what the phone connects to (plain by default). Tokens are NOT here: /var/lib/mailproxy/tokens.cache"
    echo "# After editing: systemctl restart mailproxy   (new account -> run mail-authorise)"
    echo
    if [[ -n ${MAILP_GOOGLE_EMAILS:-} ]]; then
        emit_server IMAP "$P_GIMAP" imap.gmail.com 993
        emit_server SMTP "$P_GSMTP" smtp.gmail.com 465
    fi
    if [[ -n ${MAILP_MS_EMAILS:-} ]]; then
        emit_server IMAP "$P_OIMAP" outlook.office365.com 993
        emit_server SMTP "$P_OSMTP" smtp-mail.outlook.com 587 starttls
    fi
    IFS=',' read -r -a GE <<< "${MAILP_GOOGLE_EMAILS// /}"
    for a in "${GE[@]}"; do
        [[ -n $a ]] || continue
        printf '[%s]\npermission_url = https://accounts.google.com/o/oauth2/auth\ntoken_url = https://oauth2.googleapis.com/token\n' "$a"
        printf 'oauth2_scope = https://mail.google.com/\nredirect_uri = http://localhost\nclient_id = %s\nclient_secret = %s\n\n' \
            "$MAILP_GOOGLE_CLIENT_ID" "$MAILP_GOOGLE_CLIENT_SECRET"
    done
    IFS=',' read -r -a ME <<< "${MAILP_MS_EMAILS// /}"
    for a in "${ME[@]}"; do
        [[ -n $a ]] || continue
        printf '[%s]\npermission_url = https://login.microsoftonline.com/common/oauth2/v2.0/authorize\n' "$a"
        printf 'token_url = https://login.microsoftonline.com/common/oauth2/v2.0/token\n'
        printf 'oauth2_scope = https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send offline_access\n'
        printf 'redirect_uri = http://localhost\nclient_id = %s\n' "$MAILP_MS_CLIENT_ID"
        [[ -z ${MAILP_MS_CLIENT_SECRET:-} ]] || printf 'client_secret = %s\n' "$MAILP_MS_CLIENT_SECRET"
        echo
    done
    # A wrong phone password must not wipe a stored token (upstream default True); mail-authorise --reset does it on purpose.
    printf '[emailproxy]\ndelete_account_token_on_password_error = False\n'
} > "$CONF"
chown root:mailproxy "$CONF"; chmod 0640 "$CONF"
umask 022
python3 - "$CONF" <<'PY' || die "the generated config does not parse"
import configparser, sys
cp = configparser.ConfigParser(interpolation=None); cp.read(sys.argv[1])
print("  -> config sections:", ", ".join(s if "@" not in s else s.split("@")[0][:2] + "***@" + s.split("@")[1] for s in cp.sections()))
PY
unset MAILP_GOOGLE_CLIENT_SECRET MAILP_GOOGLE_CLIENT_ID MAILP_MS_CLIENT_SECRET MAILP_MS_CLIENT_ID

# ---------------------------------------------------------------- proxy (pinned, sha256-checked) + helpers
say "installing helpers and the pinned proxy"
install -m 0644 "$HERE/files/PIN" /usr/local/share/mailproxy/PIN
install -m 0755 -o root -g root "$HERE/files/mailproxy-update" /usr/local/sbin/mailproxy-update
install -m 0755 -o root -g root "$HERE/files/mail-authorise" /usr/local/sbin/mail-authorise
install -m 0644 "$HERE/files/mailproxy.service" /etc/systemd/system/mailproxy.service
systemctl daemon-reload
# Downloads emailproxy.py at the pinned commit, refuses on a sha256 mismatch, restarts the unit, self-tests it.
systemctl enable mailproxy.service >/dev/null 2>&1
mailproxy-update /usr/local/share/mailproxy/PIN || die "mailproxy-update failed (sha256 mismatch, no egress to raw.githubusercontent.com:443, or a provider not answering on its port)"
chown -R root:root /opt/mailproxy; chmod -R go-w /opt/mailproxy

# ---------------------------------------------------------------- IPv6 off
say "disabling IPv6 (sysctl)"
cat > /etc/sysctl.d/99-mailproxy.conf <<'EOF'
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
say "writing the in-container filter (defence in depth)"
MAIL_PORTS_NFT=$(sed -n 's/^\[\(IMAP\|SMTP\)-\([0-9]*\)\]$/\2/p' "$CONF" | paste -sd, | sed 's/,/, /g')
ALLOWED_NFT=${MAILP_ALLOWED//,/, }
HOSTS_NFT=${MAILP_HOST_IPS//,/, }
PORTS_NFT=${MAILP_EGRESS_PORTS//,/, }
DHCP_IN="" DHCP_OUT=""
if [[ $DHCP == 1 ]]; then
    DHCP_IN="udp sport 67 udp dport 68 accept"
    DHCP_OUT="udp sport 68 udp dport 67 accept"
fi
cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
# Managed by container-setup.sh. DEFENCE IN DEPTH ONLY: root inside this container can flush
# this ruleset. The real wall is the Proxmox host firewall (/etc/pve/firewall/<VMID>.fw).
table inet mailfw
delete table inet mailfw
table inet mailfw {
    chain input {
        type filter hook input priority filter; policy drop;
        iifname "lo" accept
        ct state established,related accept
        ct state invalid drop
        ${DHCP_IN}
        ip saddr { ${ALLOWED_NFT} } tcp dport { ${MAIL_PORTS_NFT} } accept
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
        ip daddr ${MAILP_GW} udp dport 53 accept
        ip daddr ${MAILP_GW} tcp dport 53 accept
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

# ---------------------------------------------------------------- unattended OS security updates
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# ---------------------------------------------------------------- self-test
systemctl is-active --quiet mailproxy || { journalctl -u mailproxy -n 40 --no-pager >&2; die "mailproxy is not running"; }
say "self-test (local ports must still relay the providers' greetings with the final filter)"
mailproxy-update --selftest || warn "self-test failed -- journalctl -u mailproxy"

# ---------------------------------------------------------------- listeners + root
say "listening sockets (TCP):"
ss -H -tlnp | sed 's/^/     /'
PAT=$(sed -n 's/^\[\(IMAP\|SMTP\)-\([0-9]*\)\]$/:\2$/p' "$CONF" | paste -sd'|')
EXTRA=$(ss -H -tln | awk -v p="$PAT" '$4 !~ p && $4 !~ /^127\./ {print $4}')
[[ -z $EXTRA ]] || die "unexpected TCP listeners: ${EXTRA//$'\n'/ }"
passwd -l root >/dev/null
say "root password locked (admin from the host with: pct enter <VMID>)"
rm -rf "$STAGE" /root/mailproxy-src.tgz "$ENV_FILE" /root/mailsetup
say "container setup complete"
