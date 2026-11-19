#!/bin/sh
set -eu

destination=${1:-generic/platform=iOS Simulator}
action=${2:-build}
case "$action" in
    build|test) ;;
    *) echo "Usage: $0 [destination] [build|test]" >&2; exit 2 ;;
esac

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
set -- -project "$root/iPad/ModEdit-iPad.xcodeproj" \
    -scheme ModEdit-iPad -destination "$destination" \
    -derivedDataPath "${MODEDIT_DERIVED_DATA:-$root/iPad/DerivedData}"

case "$destination" in
    "platform=iOS,"*|"generic/platform=iOS")
        if [ -z "${MODEDIT_SIGNING_TEAM:-}" ]; then
            echo "Set MODEDIT_SIGNING_TEAM to your Apple development team identifier." >&2
            exit 2
        fi
        set -- "$@" -sdk iphoneos \
            "DEVELOPMENT_TEAM=$MODEDIT_SIGNING_TEAM" -allowProvisioningUpdates
        ;;
    "platform=iOS Simulator,"*|"generic/platform=iOS Simulator")
        set -- "$@" -sdk iphonesimulator CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
        ;;
    *)
        echo "Choose an iOS or iOS Simulator destination." >&2
        exit 2
        ;;
esac

exec xcodebuild "$@" "$action"
