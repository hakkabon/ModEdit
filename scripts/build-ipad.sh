#!/bin/sh
set -eu
action=${2:-build}
case "$action" in
    build|test) ;;
    *) echo "Usage: $0 [destination] [build|test]" >&2; exit 2 ;;
esac
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
xcodebuild -project "$root/iPad/ModEdit-iPad.xcodeproj" \
    -scheme ModEdit-iPad -sdk iphonesimulator \
    -destination "${1:-generic/platform=iOS Simulator}" \
    -derivedDataPath "$root/iPad/DerivedData" \
    IPHONEOS_DEPLOYMENT_TARGET=17.0 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- "$action"
