#!/usr/bin/env bash
# ios6-revival mail bridge -- Proxmox VE installer (bootstrap).
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/stevenjc2009-byte/ios6-revival/main/proxmox/mail/install.sh)"
#
# Run as root on the Proxmox host. Builds its OWN locked-down unprivileged LXC container (separate
# from the YouTube one), writes a HOST-side Proxmox firewall for it, and installs the pinned
# email-oauth2-proxy. A `curl | bash` one-liner only delivers this one file, so this bootstrap
# downloads the repo tarball (codeload.github.com, https) and hands over to proxmox/mail/install-main.sh.
# Read that first if you like: https://github.com/stevenjc2009-byte/ios6-revival/tree/main/proxmox/mail
#
# Copied from ../install.sh (copy, don't depend) and adapted.
# Run from a checkout instead (no GitHub needed): ./proxmox/mail/install.sh
# Rehearse without changing anything:             MAILP_DRY_RUN=1 ./proxmox/mail/install.sh
set -Eeuo pipefail

REPO_OWNER="${MAILP_REPO_OWNER:-stevenjc2009-byte}"
REPO_NAME="${MAILP_REPO_NAME:-ios6-revival}"
REPO_BRANCH="${MAILP_REPO_BRANCH:-main}"      # a branch, tag or commit sha

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mxxx\033[0m %s\n' "$*" >&2; exit 1; }
DRY_RUN=${MAILP_DRY_RUN:-0}

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

WORK=$(mktemp -d /tmp/mailproxy-install.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- get the source
SELF=${BASH_SOURCE[0]:-}
ROOT=${MAILP_LOCAL_SRC:-}
if [[ -z $ROOT && -n $SELF && -f $SELF && -f $(dirname "$SELF")/install-main.sh ]]; then
    ROOT=$(cd "$(dirname "$SELF")/../.." && pwd)
fi
if [[ -n $ROOT ]]; then
    [[ -f $ROOT/proxmox/mail/install-main.sh && -f $ROOT/proxmox/mail/files/PIN ]] \
        || die "$ROOT is not an ios6-revival checkout (need proxmox/mail/install-main.sh and files/PIN)"
    say "using local checkout $ROOT"
else
    URL="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/${REPO_BRANCH}"
    say "downloading ${URL}"
    curl -fsSL --proto '=https' --tlsv1.2 -o "$WORK/src.tgz" "$URL" || die "download failed (repo public? branch name right?)"
    mkdir "$WORK/src"
    tar -xzf "$WORK/src.tgz" -C "$WORK/src" --strip-components=1
    ROOT=$WORK/src
    say "source sha256: $(sha256sum "$WORK/src.tgz" | cut -d' ' -f1)"
    [[ -f $ROOT/proxmox/mail/install-main.sh && -f $ROOT/proxmox/mail/files/PIN ]] \
        || die "the tarball has no proxmox/mail/install-main.sh -- is the mail bridge on branch ${REPO_BRANCH}?"
fi

# ---------------------------------------------------------------- hand over
export REPO_OWNER REPO_NAME REPO_BRANCH MAILP_SRC_ROOT=$ROOT
bash "$ROOT/proxmox/mail/install-main.sh" "$@"
