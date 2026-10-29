#!/usr/bin/env bash
# ytserver-update -- daily updater, runs inside the container as root via
# ytserver-update.service. Output goes to the journal:
#     journalctl -u ytserver-update
#
# 1. fetch the repo tarball, take server/ and proxmox/files/
# 2. this script changed -> install the new one and run that instead
# 3. units changed -> install them (old copies kept for rollback), daemon-reload
# 4. build server/ into /opt/ytserver.next with a NEW venv (requirements + newest yt-dlp)
# 5. if nothing changed since the running build, stop here (restart + self-test
#    first if ytserver.service changed)
# 6. swap it in, restart ytserver, self-test (/healthz + one real search)
# 7. self-test fails -> put the previous tree and units back, restart, exit 1
#
#   ytserver-update --selftest    only run the self-test against the running service
set -Eeuo pipefail
umask 022

# shellcheck disable=SC1091
. /etc/ytserver/update.env        # REPO_OWNER REPO_NAME REPO_BRANCH SELFTEST_PATH
PORT=8080
if [[ -r /etc/ytserver/ytserver.env ]]; then
    PORT=$(sed -n 's/^YTS_PORT=//p' /etc/ytserver/ytserver.env | tail -1)
    PORT=${PORT:-8080}
fi
APP=/opt/ytserver
NEXT=/opt/ytserver.next
PREV=/opt/ytserver.prev
UNITS_PREV=/opt/ytserver.units-prev
SELF=/usr/local/sbin/ytserver-update
UNIT_DIR=/etc/systemd/system
UNITS=(ytserver.service ytserver-update.service ytserver-update.timer)
URL="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/${REPO_BRANCH}"

log() { echo "ytserver-update: $*"; }

selftest() {
    local i body
    for i in $(seq 1 40); do
        [[ $(curl -fsS -m 3 "http://127.0.0.1:${PORT}/healthz" 2>/dev/null || true) == ok* ]] && break
        sleep 1
        [[ $i -eq 40 ]] && { log "selftest: /healthz never answered 'ok'"; return 1; }
    done
    body=$(curl -fsS -m 90 "http://127.0.0.1:${PORT}${SELFTEST_PATH}" 2>&1) || {
        log "selftest: search request failed: ${body:0:300}"; return 1; }
    [[ ${#body} -gt 20 ]] || { log "selftest: search returned an empty answer"; return 1; }
    log "selftest: ok (healthz + search returned ${#body} bytes)"
}

# Put back the unit files this run replaced (kept in $UNITS_PREV).
restore_units() {
    local u
    [[ ${#CHANGED_UNITS[@]} -gt 0 ]] || return 0
    for u in "${CHANGED_UNITS[@]}"; do
        if [[ -f $UNITS_PREV/$u ]]; then install -m 0644 "$UNITS_PREV/$u" "$UNIT_DIR/$u"; else rm -f "$UNIT_DIR/$u"; fi
    done
    systemctl daemon-reload
    log "unit files put back: ${CHANGED_UNITS[*]}"
}

if [[ ${1:-} == "--selftest" ]]; then selftest; exit $?; fi

mkdir -p /run/ytserver-update
exec 9>/run/ytserver-update/lock
flock -n 9 || { log "another update is already running"; exit 0; }

WORK=$(mktemp -d /opt/.ytupdate.XXXXXX)
# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() { rm -rf "$WORK" "$NEXT"; }
trap cleanup EXIT

log "fetching ${URL}"
curl -fsSL --proto '=https' --tlsv1.2 -m 300 -o "$WORK/src.tgz" "$URL"
TOP=$(tar -tzf "$WORK/src.tgz" | sed -n 1p | cut -d/ -f1)   # not head: under systemd tar gets EPIPE and exits 2
tar -xzf "$WORK/src.tgz" --no-same-owner -C "$WORK" "${TOP}/server" "${TOP}/proxmox/files"
[[ -f $WORK/$TOP/server/requirements.txt ]] || { log "tarball has no server/requirements.txt"; exit 1; }
FILES=$WORK/$TOP/proxmox/files

# A new updater runs straight away, so its own changes apply to this run. install makes a
# new file, so this bash keeps reading the old one until exec.
if [[ -z ${YTS_UPDATER_REEXEC:-} ]] && ! cmp -s "$FILES/ytserver-update.sh" "$SELF"; then
    if install -m 0755 -o root -g root "$FILES/ytserver-update.sh" "$SELF" 2>/dev/null; then
        log "updater changed; running the new one"
        cleanup; trap - EXIT
        exec 9>&-
        YTS_UPDATER_REEXEC=1 exec "$SELF"
    fi
    log "cannot replace ${SELF} (read-only here); run the one-time refresh in proxmox/README.md"
fi

CHANGED_UNITS=()
rm -rf "$UNITS_PREV"; mkdir -p "$UNITS_PREV"
for u in "${UNITS[@]}"; do
    cmp -s "$FILES/$u" "$UNIT_DIR/$u" && continue
    [[ -f $UNIT_DIR/$u ]] && cp -a "$UNIT_DIR/$u" "$UNITS_PREV/$u"
    if ! install -m 0644 -o root -g root "$FILES/$u" "$UNIT_DIR/$u" 2>/dev/null; then
        log "cannot replace ${UNIT_DIR}/${u} (read-only here); run the one-time refresh in proxmox/README.md"
        continue
    fi
    CHANGED_UNITS+=("$u")
done
if [[ ${#CHANGED_UNITS[@]} -gt 0 ]]; then
    systemctl daemon-reload
    log "unit files updated: ${CHANGED_UNITS[*]}"
fi

rm -rf "$NEXT"
mkdir "$NEXT"
cp -a "$WORK/$TOP/server/." "$NEXT/"
python3 -m venv "$NEXT/venv"
"$NEXT/venv/bin/python" -m pip install -q -r "$NEXT/requirements.txt"
"$NEXT/venv/bin/python" -m pip install -q --upgrade "yt-dlp[default]"

# Fingerprint = every source file + every installed package version.
BUILD_ID=$( { (cd "$NEXT" && find . -path ./venv -prune -o -type f -print0 | sort -z \
                  | xargs -0 sha256sum); "$NEXT/venv/bin/python" -m pip freeze; } | sha256sum | cut -d' ' -f1)
if [[ -f $APP/.build-id && $(cat "$APP/.build-id") == "$BUILD_ID" ]]; then
    if [[ " ${CHANGED_UNITS[*]} " != *" ytserver.service "* ]]; then
        log "already up to date ($(${APP}/venv/bin/python -m pip show yt-dlp | sed -n 's/^Version: //p'))"
        exit 0
    fi
    log "server unchanged but ytserver.service changed; restarting"
    systemctl restart ytserver
    if selftest; then log "update complete"; exit 0; fi
    log "SELFTEST FAILED -- putting the old unit files back"
    restore_units
    systemctl restart ytserver
    selftest || log "ROLLBACK ALSO FAILED the self-test -- check: journalctl -u ytserver"
    exit 1
fi
echo "$BUILD_ID" > "$NEXT/.build-id"
find "$NEXT" -path "$NEXT/venv" -prune -o -type d -exec chmod 0755 {} +
chmod -R go-w "$NEXT"
NEW_VER=$("$NEXT/venv/bin/python" -m pip show yt-dlp | sed -n 's/^Version: //p')
log "built new tree (yt-dlp ${NEW_VER}); swapping in"

# NOTE: the venv is built at $NEXT then renamed. That is fine for `python -m
# ytserver` (the interpreter finds pyvenv.cfg next to itself); only the pip
# console-script shebangs would be stale, and nothing here uses them.
systemctl stop ytserver
rm -rf "$PREV"
mv "$APP" "$PREV"
mv "$NEXT" "$APP"
systemctl start ytserver

if selftest; then
    log "update complete; previous tree kept in ${PREV} until the next run"
    exit 0
fi

log "SELFTEST FAILED -- rolling back to the previous tree"
systemctl stop ytserver || true
rm -rf "$APP"
mv "$PREV" "$APP"
restore_units
systemctl start ytserver
if selftest; then
    log "rolled back; previous version is serving again"
else
    log "ROLLBACK ALSO FAILED the self-test -- check: journalctl -u ytserver"
fi
exit 1
