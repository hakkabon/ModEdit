#!/bin/sh
# Build and test a copy of the working tree with no local package paths.
#
# This is a pre-release check, not the normal edit loop. It copies the tree to a
# temporary directory, excludes build products, resolves dependencies from a
# fresh scratch path, and runs the version and ecosystem checks there.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/modedit-clean.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

DEST="$TMP/ModEdit"
SCRATCH="$TMP/scratch"
mkdir -p "$DEST"

rsync -a \
    --exclude '.git' \
    --exclude '.build' \
    --exclude 'dist' \
    --exclude 'iPad/DerivedData' \
    --exclude '.swiftpm' \
    --exclude '__pycache__' \
    "$ROOT/" "$DEST/"

cd "$DEST"
echo "Clean checkout: $DEST"

scripts/version.sh check
scripts/verify-ecosystem-versions.sh

swift package resolve --scratch-path "$SCRATCH"
swift build --scratch-path "$SCRATCH"
swift test --scratch-path "$SCRATCH"

echo "Clean checkout passed."
