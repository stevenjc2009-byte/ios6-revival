#!/usr/bin/env bash
# wxserver-update -- daily updater, runs inside the container as root via
# wxserver-update.service. Output goes to the journal:
#     journalctl -u wxserver-update
#
# What it updates: the stock-data library (yfinance), which breaks whenever
# Yahoo changes its pages. It does NOT re-fetch the server code or the overlay
# (those are pinned and tree-hash checked at install time); to change those,
# re-run the installer from the Proxmox host. Steps:
#
# 1. copy /opt/wxserver to /opt/wxserver.next and upgrade yfinance there
# 2. if the installed package set is unchanged, stop
# 3. swap it in, restart wxserver, run `probe.py --only stocks`
# 4. probe fails -> swap the previous tree back, restart, exit 1
#
#   wxserver-update --selftest    only probe the running service (weather + stocks)
set -Eeuo pipefail
umask 022

PORT=8000
if [[ -r /etc/wxserver/wxserver.env ]]; then
    PORT=$(sed -n 's/^WXS_PORT=//p' /etc/wxserver/wxserver.env | tail -1)
    PORT=${PORT:-8000}
fi
APP=/opt/wxserver
NEXT=/opt/wxserver.next
PREV=/opt/wxserver.prev

log() { echo "wxserver-update: $*"; }

# selftest ONLY : "all" (default) or "stocks"
selftest() {
    local i out
    for i in $(seq 1 40); do
        [[ $(curl -fsS -m 3 "http://127.0.0.1:${PORT}/dgw" 2>/dev/null || true) == ok* ]] && break
        sleep 1
        [[ $i -eq 40 ]] && { log "selftest: server never answered 'ok' on /dgw"; return 1; }
    done
    if out=$("$APP/venv/bin/python" "$APP/probe.py" --base "http://127.0.0.1:${PORT}" --only "${1:-all}" 2>&1); then
        log "selftest: ok ($(sed -n '$p' <<<"$out"))"
    else
        log "selftest FAILED:"; grep -E '^(FAIL|probe:)' <<<"$out" | sed 's/^/    /' || true
        return 1
    fi
}

if [[ ${1:-} == "--selftest" ]]; then selftest all; exit $?; fi

mkdir -p /run/wxserver-update
exec 9>/run/wxserver-update/lock
flock -n 9 || { log "another update is already running"; exit 0; }

# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() { rm -rf "$NEXT"; }
trap cleanup EXIT

rm -rf "$NEXT"
cp -a "$APP" "$NEXT"
# The copied venv's pyvenv.cfg still works (the interpreter finds it next to
# itself); only pip console-script shebangs would be stale, and nothing here uses them.
# --only-binary: there is no compiler in the container.
"$NEXT/venv/bin/python" -m pip install -q --upgrade --only-binary=:all: yfinance

BUILD_ID=$("$NEXT/venv/bin/python" -m pip freeze | sha256sum | cut -d' ' -f1)
if [[ -f $APP/.build-id && $(cat "$APP/.build-id") == "$BUILD_ID" ]]; then
    log "already up to date (yfinance $("$APP/venv/bin/python" -m pip show yfinance | sed -n 's/^Version: //p'))"
    exit 0
fi
OLD_VER=$("$APP/venv/bin/python" -m pip show yfinance | sed -n 's/^Version: //p')
NEW_VER=$("$NEXT/venv/bin/python" -m pip show yfinance | sed -n 's/^Version: //p')
echo "$BUILD_ID" > "$NEXT/.build-id"
log "built new tree (yfinance ${OLD_VER} -> ${NEW_VER}); swapping in"

systemctl stop wxserver
rm -rf "$PREV"
mv "$APP" "$PREV"
mv "$NEXT" "$APP"
systemctl start wxserver

# Weather does not depend on yfinance, so only stocks gate the swap.
if selftest stocks; then
    log "update complete; previous tree kept in ${PREV} until the next run"
    exit 0
fi

log "SELFTEST FAILED -- rolling back to the previous tree"
systemctl stop wxserver || true
rm -rf "$APP"
mv "$PREV" "$APP"
systemctl start wxserver
if selftest stocks; then
    log "rolled back; previous version is serving again"
else
    log "ROLLBACK ALSO FAILED the self-test -- check: journalctl -u wxserver"
fi
exit 1
