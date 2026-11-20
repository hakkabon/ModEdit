#!/bin/sh
# Validate Release/EcosystemVersions.json and ModEdit's dependency pins.
#
# Usage:
#   scripts/verify-ecosystem-versions.sh
#   scripts/verify-ecosystem-versions.sh --root /path/to/sibling/checkouts
#   scripts/verify-ecosystem-versions.sh --root ... --update
#
# Without --root, only the snapshot schema, local-path check, direct dependency
# pins, and ModEdit version are validated. With --root, every sibling checkout
# must also be exactly at the recorded tag.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec python3 "$ROOT/scripts/ecosystem_versions.py" "$@"
