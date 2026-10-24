#!/bin/sh
# Assembles ModEdit.app from the SwiftPM build.
#
# `swift run` starts the executable without an app bundle, so the document types
# and identifiers in Info.plist are never registered and Finder cannot open files
# with it. This script wraps the binary in a minimal bundle.
#
# Usage: scripts/make-app.sh [debug|release]
set -eu

CONFIG="${1:-debug}"
cd "$(dirname "$0")/.."

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$BIN_DIR/ModEdit.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ModEdit" "$APP/Contents/MacOS/ModEdit"
cp Sources/ModEditApp/Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature so Gatekeeper/launch services accept the bundle locally.
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warning: codesign failed (continuing)"

echo "Built: $APP"
echo "Run:   open \"$APP\""
