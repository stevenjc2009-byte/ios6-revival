#!/usr/bin/env bash
# ios6-revival ytserver -- Proxmox VE installer (bootstrap).
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/stevenjc2009-byte/ios6-revival/main/proxmox/install.sh)"
#
# Run as root on the Proxmox host. It builds a locked-down unprivileged LXC
# container, writes a HOST-side Proxmox firewall for it, and installs server/.
# A `curl | bash` one-liner only delivers this one file, so this bootstrap
# downloads the repo tarball (codeload.github.com, https) and hands over to
# proxmox/install-main.sh inside it. Read that file first if you like:
#   https://github.com/stevenjc2009-byte/ios6-revival/tree/main/proxmox
#
# Run from a checkout instead (no GitHub needed): ./proxmox/install.sh
# Rehearse without changing anything:            YTS_DRY_RUN=1 ./proxmox/install.sh
set -Eeuo pipefail

REPO_OWNER="${YTS_REPO_OWNER:-stevenjc2009-byte}"
REPO_NAME="${YTS_REPO_NAME:-ios6-revival}"
REPO_BRANCH="${YTS_REPO_BRANCH:-main}"      # a branch, tag or commit sha

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mxxx\033[0m %s\n' "$*" >&2; exit 1; }
DRY_RUN=${YTS_DRY_RUN:-0}

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

WORK=$(mktemp -d /tmp/ytserver-install.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- get the source
SELF=${BASH_SOURCE[0]:-}
ROOT=${YTS_LOCAL_SRC:-}
if [[ -z $ROOT && -n $SELF && -f $SELF && -f $(dirname "$SELF")/install-main.sh ]]; then
    ROOT=$(cd "$(dirname "$SELF")/.." && pwd)
fi
if [[ -n $ROOT ]]; then
    [[ -f $ROOT/proxmox/install-main.sh && -f $ROOT/server/requirements.txt ]] \
        || die "$ROOT is not an ios6-revival checkout (need proxmox/install-main.sh and server/requirements.txt)"
    say "using local checkout $ROOT"
    TARBALL=$WORK/src.tgz
    tar -C "$(dirname "$ROOT")" -czf "$TARBALL" \
        --exclude=.git --exclude=__pycache__ --exclude='*.pyc' --exclude='venv' --exclude='.venv' \
        --exclude='*/server/cache' "$(basename "$ROOT")"
else
    URL="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/${REPO_BRANCH}"
    say "downloading ${URL}"
    TARBALL=$WORK/src.tgz
    curl -fsSL --proto '=https' --tlsv1.2 -o "$TARBALL" "$URL" || die "download failed (repo public? branch name right?)"
    mkdir "$WORK/src"
    tar -xzf "$TARBALL" -C "$WORK/src" --strip-components=1
    ROOT=$WORK/src
    say "source sha256: $(sha256sum "$TARBALL" | cut -d' ' -f1)"
    [[ -f $ROOT/proxmox/install-main.sh && -f $ROOT/server/requirements.txt ]] \
        || die "the tarball has no proxmox/install-main.sh or server/requirements.txt"
fi

# ---------------------------------------------------------------- hand over
export REPO_OWNER REPO_NAME REPO_BRANCH YTS_SRC_ROOT=$ROOT YTS_TARBALL=$TARBALL
bash "$ROOT/proxmox/install-main.sh" "$@"
