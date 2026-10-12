#!/bin/sh
# Package Work Mac Setup for a GitHub release: a staged copy without extended
# attributes, ACLs, or resource forks, stripped and re-signed ad hoc with the
# Hardened Runtime, checked for local paths and build-machine metadata, then
# written to a deterministic ZIP next to a SHA-256 checksum file.
#
# The result is ad-hoc signed only. It is not Developer ID signed or notarized.
# Set SKIP_BUILD=1 to package the app already in dist/ instead of rebuilding.
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
umask 077
cd -P "$(dirname "$0")/.."

fail() { echo "$*" >&2; exit 1; }

APP='Work Mac Setup.app'
BUILT="dist/$APP"
ZIP='Work-Mac-Setup.zip'
OUT='dist/release'

if [ "${SKIP_BUILD:-0}" != 1 ]; then
    ./build-app.sh >/dev/null
fi
[ -d "$BUILT" ] && [ ! -L "$BUILT" ] || fail "Missing built app: $BUILT"
[ ! -L "$OUT" ] || fail "Refusing linked output directory: $OUT"
/bin/mkdir -p "$OUT"
[ ! -L "$OUT/$ZIP" ] || fail "Refusing linked archive destination."

WORK=$(/usr/bin/mktemp -d "dist/.release-stage.XXXXXX")
trap '/bin/rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

/usr/bin/ditto --noextattr --noacl --norsrc "$BUILT" "$WORK/$APP"
/usr/bin/python3 Tools/release-privacy.py --prepare --archive "$WORK/$ZIP" "$WORK/$APP"
/bin/mv -f "$WORK/$ZIP" "$OUT/$ZIP"
(cd "$OUT" && /usr/bin/shasum -a 256 "$ZIP" > SHA256SUMS.txt)

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT/Contents/Info.plist")
echo "Wrote $OUT/$ZIP and $OUT/SHA256SUMS.txt for Work Mac Setup $version (ad-hoc signed, not notarized)."
