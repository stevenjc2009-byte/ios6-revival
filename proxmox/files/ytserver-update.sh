#!/usr/bin/env bash
# ytserver-update -- daily updater, runs inside the container as root via
# ytserver-update.service. Output goes to the journal:
#     journalctl -u ytserver-update
#
# 1. fetch the repo tarball, take server/
# 2. build it into /opt/ytserver.next with a NEW venv (requirements + newest yt-dlp)
# 3. if nothing changed since the running build, stop here
# 4. swap it in, restart ytserver, self-test (/healthz + one real search)
# 5. self-test fails -> swap the previous tree back, restart, exit 1
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
TOP=$(tar -tzf "$WORK/src.tgz" | head -1 | cut -d/ -f1)
tar -xzf "$WORK/src.tgz" --no-same-owner -C "$WORK" "${TOP}/server"
[[ -f $WORK/$TOP/server/requirements.txt ]] || { log "tarball has no server/requirements.txt"; exit 1; }

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
    log "already up to date ($(${APP}/venv/bin/python -m pip show yt-dlp | sed -n 's/^Version: //p'))"
    exit 0
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
systemctl start ytserver
if selftest; then
    log "rolled back; previous version is serving again"
else
    log "ROLLBACK ALSO FAILED the self-test -- check: journalctl -u ytserver"
fi
exit 1
