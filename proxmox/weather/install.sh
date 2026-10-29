#!/usr/bin/env bash
# ios6-revival weather + stocks server -- Proxmox VE installer (bootstrap).
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/stevenjc2009-byte/ios6-revival/main/proxmox/weather/install.sh)"
#
# Run as root on the Proxmox host. It builds a SECOND, separate locked-down
# unprivileged LXC container (not the YouTube one), writes a HOST-side Proxmox
# firewall for it, and installs a self-hosted server for the WeatherX tweak.
# A `curl | bash` one-liner only delivers this one file, so this bootstrap
# downloads the repo tarball (codeload.github.com, https) and hands over to
# proxmox/weather/install-main.sh inside it. Read that file first if you like.
#
# Run from a checkout instead (no GitHub needed): ./proxmox/weather/install.sh
# Rehearse without changing anything:            WXS_DRY_RUN=1 ./proxmox/weather/install.sh
set -Eeuo pipefail

REPO_OWNER="${WXS_REPO_OWNER:-stevenjc2009-byte}"
REPO_NAME="${WXS_REPO_NAME:-ios6-revival}"
REPO_BRANCH="${WXS_REPO_BRANCH:-main}"      # a branch, tag or commit sha

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mxxx\033[0m %s\n' "$*" >&2; exit 1; }
DRY_RUN=${WXS_DRY_RUN:-0}

# ---------------------------------------------------------------- preflight
command -v curl >/dev/null || die "curl is required (apt install curl)"
command -v tar >/dev/null || die "tar is required"
if [[ $DRY_RUN -eq 0 ]]; then
    [[ $EUID -eq 0 ]] || die "run as root on the Proxmox host"
    command -v pveversion >/dev/null || die "pveversion not found: this is not a Proxmox VE host"
    PVE_MAJOR=$(pveversion | sed -n 's|^pve-manager/\([0-9]*\)\..*|\1|p')
    [[ ${PVE_MAJOR:-0} -ge 8 ]] || die "Proxmox VE 8 or newer is required (found: $(pveversion))"
    say "$(pveversion)"
fi

WORK=$(mktemp -d /tmp/wxserver-install.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- get the source
SELF=${BASH_SOURCE[0]:-}
ROOT=${WXS_LOCAL_SRC:-}
if [[ -z $ROOT && -n $SELF && -f $SELF && -f $(dirname "$SELF")/install-main.sh ]]; then
    ROOT=$(cd "$(dirname "$SELF")/../.." && pwd)
fi
NEED="proxmox/weather/install-main.sh"
if [[ -n $ROOT ]]; then
    [[ -f $ROOT/$NEED && -f $ROOT/proxmox/weather/files/requirements.txt ]]         || die "$ROOT is not an ios6-revival checkout (need $NEED and proxmox/weather/files/requirements.txt)"
    say "using local checkout $ROOT"
else
    URL="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/${REPO_BRANCH}"
    say "downloading ${URL}"
    curl -fsSL --proto '=https' --tlsv1.2 -o "$WORK/repo.tgz" "$URL" || die "download failed (repo public? branch name right?)"
    mkdir "$WORK/src"
    tar -xzf "$WORK/repo.tgz" -C "$WORK/src" --strip-components=1
    ROOT=$WORK/src
    say "source sha256: $(sha256sum "$WORK/repo.tgz" | cut -d' ' -f1)"
    [[ -f $ROOT/$NEED && -f $ROOT/proxmox/weather/files/requirements.txt ]]         || die "the tarball has no $NEED or proxmox/weather/files/requirements.txt (is the weather installer on that branch?)"
fi
# Only the weather installer goes into the container; keep that tarball small.
TARBALL=$WORK/src.tgz
tar -C "$ROOT" -czf "$TARBALL" --exclude=__pycache__ --exclude='*.pyc' --transform 's,^,src/,' proxmox/weather

# ---------------------------------------------------------------- hand over
export REPO_OWNER REPO_NAME REPO_BRANCH WXS_SRC_ROOT=$ROOT WXS_TARBALL=$TARBALL
bash "$ROOT/proxmox/weather/install-main.sh" "$@"
