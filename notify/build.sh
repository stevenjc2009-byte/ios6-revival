#!/bin/bash
# Run inside WSL: builds in ~/ios6-notify-build (no spaces in path) and copies the deb to packages/.
set -e
SRC="/mnt/c/Users/steve/Documents/fuck u/ios6-revival/notify"
B=~/ios6-notify-build
export THEOS=~/theos
mkdir -p "$B"
rsync -a --delete --exclude packages --exclude .theos --exclude obj "$SRC"/ "$B"/
[ -d "$B/layout" ] && { find "$B/layout" -type d -exec chmod 755 {} + ; find "$B/layout" -type f -exec chmod 644 {} + ; } || true
cd "$B"
make clean >/dev/null 2>&1 || true
make package 2>&1 | tee ~/notify-build.log | tail -40
mkdir -p "$SRC/packages"
cp -f packages/*.deb "$SRC/packages/"
ls -l "$SRC/packages"
