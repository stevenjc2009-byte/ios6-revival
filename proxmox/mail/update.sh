#!/usr/bin/env bash
# update.sh -- update the mail-bridge container. Run as root on the Proxmox host:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/stevenjc2009-byte/ios6-revival/main/proxmox/mail/update.sh)" _ <VMID>
#   or from a checkout:   ./proxmox/mail/update.sh <VMID>
#
# What it does: (1) fetches the repo's current files/PIN (the pinned email-oauth2-proxy release + sha256),
# (2) pushes it and the updater scripts into the container, (3) runs mailproxy-update there (download,
# sha256 check, swap, self-test, automatic rollback), (4) apt upgrade inside the container.
# It needs tcp/80 for apt only if the container's firewall allows it; the final firewall does not, so apt
# runs over https (container-setup.sh switched the sources). Tokens and config are never touched.
#   MAILP_REPO_OWNER / MAILP_REPO_NAME / MAILP_REPO_BRANCH   where to fetch from (default main)
#   MAILP_LOCAL_SRC=/path/to/checkout                        use a local checkout instead of GitHub
set -Eeuo pipefail

REPO_OWNER="${MAILP_REPO_OWNER:-stevenjc2009-byte}"
REPO_NAME="${MAILP_REPO_NAME:-ios6-revival}"
REPO_BRANCH="${MAILP_REPO_BRANCH:-main}"
say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mxxx\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root on the Proxmox host"
command -v pct >/dev/null || die "pct not found: not a Proxmox host"
VMID=${1:-${MAILP_VMID:-}}
[[ $VMID =~ ^[0-9]+$ ]] || die "usage: $0 VMID"
pct config "$VMID" | grep -q '^tags:.*ios6-revival' || die "CT $VMID is not tagged ios6-revival"
[[ $(pct status "$VMID") == *running* ]] || die "CT $VMID is not running"
pct exec "$VMID" -- test -x /usr/local/sbin/mailproxy-update || die "CT $VMID is not a mail-bridge container (no mailproxy-update)"

WORK=$(mktemp -d /tmp/mailproxy-update.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
ROOT=${MAILP_LOCAL_SRC:-}
SELF=${BASH_SOURCE[0]:-}
if [[ -z $ROOT && -n $SELF && -f $SELF && -f $(dirname "$SELF")/files/PIN ]]; then
    ROOT=$(cd "$(dirname "$SELF")/../.." && pwd)
fi
if [[ -z $ROOT ]]; then
    URL="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/${REPO_BRANCH}"
    say "downloading ${URL}"
    curl -fsSL --proto '=https' --tlsv1.2 -o "$WORK/src.tgz" "$URL" || die "download failed"
    mkdir "$WORK/src"; tar -xzf "$WORK/src.tgz" -C "$WORK/src" --strip-components=1
    ROOT=$WORK/src
fi
F=$ROOT/proxmox/mail/files
for f in PIN mailproxy-update mail-authorise mailproxy.service; do [[ -f $F/$f ]] || die "missing $F/$f"; done
# shellcheck disable=SC1091
. "$F/PIN"
say "target proxy: ${MAILP_PROXY_VERSION} (${MAILP_PROXY_COMMIT:0:12}), sha256 ${MAILP_PROXY_SHA256:0:16}..."

say "pushing the updater and helpers into CT ${VMID}"
pct push "$VMID" "$F/PIN" /usr/local/share/mailproxy/PIN --perms 0644
pct push "$VMID" "$F/mailproxy-update" /usr/local/sbin/mailproxy-update --perms 0755
pct push "$VMID" "$F/mail-authorise" /usr/local/sbin/mail-authorise --perms 0755
pct push "$VMID" "$F/mailproxy.service" /etc/systemd/system/mailproxy.service --perms 0644
pct exec "$VMID" -- systemctl daemon-reload

say "updating the proxy (sha256 check, self-test, rollback on failure)"
pct exec "$VMID" -- /usr/local/sbin/mailproxy-update /usr/local/share/mailproxy/PIN

say "OS packages (apt over https)"
pct exec "$VMID" -- bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get -y -qq -o Dpkg::Options::=--force-confold full-upgrade && apt-get -y -qq autoremove --purge && apt-get clean' \
    || echo "apt step failed (egress is 443 only; see README, Updates). The proxy update above already succeeded."
say "done. Tokens and config were not touched. Check: pct exec ${VMID} -- journalctl -u mailproxy -n 20 --no-pager"
