#!/bin/sh
# Builds a release .app and packages it as a zip for distribution.
#
# Usage: scripts/package-release.sh
# Env:   DIST_DIR  output directory (default: dist)
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

scripts/make-app.sh release

BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$BIN_DIR/ModEdit.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$APP/Contents/Info.plist")
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
ARCHIVE="$DIST_DIR/ModEdit-$VERSION-macos.zip"

mkdir -p "$DIST_DIR"
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
unzip -tq "$ARCHIVE" >/dev/null

echo "Packaged: $ARCHIVE"
shasum -a 256 "$ARCHIVE"
