#!/bin/sh
# Single-source version management for ModEdit.
#
# Version.json is the source of truth. This script mirrors it into the app and
# iPad Info.plists, the Swift version constant, and the README marker.
#
# Usage:
#   scripts/version.sh                 # show version, build and channel
#   scripts/version.sh check           # fail if generated metadata is stale
#   scripts/version.sh sync            # regenerate metadata from Version.json
#   scripts/version.sh bump patch      # bump and sync
#   scripts/version.sh set 0.42.0      # set an explicit version and sync
#   scripts/version.sh verify-tag      # check HEAD tag == Version.json
#   scripts/version.sh tag             # create an annotated release tag
#
# See Docs/Versioning.md for the release policy.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec python3 "$ROOT/scripts/version_tool.py" "$@"
