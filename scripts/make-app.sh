#!/bin/sh
# Assembles ModEdit.app from the SwiftPM build.
#
# `swift run` starts the executable without an app bundle, so the document types
# and identifiers in Info.plist are never registered and Finder cannot open files
# with it. This script wraps the binary in a minimal, ad-hoc-signed bundle.
#
# Usage: scripts/make-app.sh [debug|release]
set -eu

CONFIG="${1:-debug}"
case "$CONFIG" in
    debug|release) ;;
    *)
        echo "usage: $0 [debug|release]" >&2
        exit 2
        ;;
esac

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

INFO_PLIST="Sources/ModEditApp/Resources/Info.plist"
plutil -lint "$INFO_PLIST" >/dev/null

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$BIN_DIR/ModEdit.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

install -m 755 "$BIN_DIR/ModEdit" "$APP/Contents/MacOS/ModEdit"
install -m 644 "$INFO_PLIST" "$APP/Contents/Info.plist"
install -m 644 LICENSE "$APP/Contents/Resources/LICENSE"
# Classic bundle signature: an application with a high-level (????) creator.
printf 'APPL????' > "$APP/Contents/PkgInfo"

plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Ad-hoc signature so Gatekeeper/launch services accept the bundle locally.
if codesign --force --sign - "$APP" >/dev/null 2>&1; then
    codesign --verify --deep --strict "$APP"
else
    echo "warning: codesign failed (continuing with unsigned bundle)" >&2
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$APP/Contents/Info.plist")
ARCHS=$(lipo -archs "$APP/Contents/MacOS/ModEdit" 2>/dev/null || echo unknown)

echo "Built:   $APP"
echo "Version: $VERSION ($ARCHS)"
echo "Run:     open \"$APP\""
