#!/bin/bash
# Run inside WSL: builds in ~/ios6-tweak-build (no spaces in path) and copies the deb to packages/.
set -e
SRC="/mnt/c/Users/steve/Documents/fuck u/ios6-revival/tweak"
B=~/ios6-tweak-build
export THEOS=~/theos
mkdir -p "$B"
rsync -a --delete --exclude packages --exclude .theos --exclude obj "$SRC"/ "$B"/
find "$B/layout" -type d -exec chmod 755 {} + ; find "$B/layout" -type f -exec chmod 644 {} +
cd "$B"
make clean >/dev/null 2>&1 || true
make package 2>&1 | tee ~/tweak-agent-build.log | tail -40
mkdir -p "$SRC/packages"
cp -f packages/*.deb "$SRC/packages/"
ls -l "$SRC/packages"
