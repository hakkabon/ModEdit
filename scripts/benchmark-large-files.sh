#!/bin/sh
# Runs the 10 MB / 50 MB large-file benchmark in release mode.
#
# The benchmark is a Swift Testing suite that stays disabled during normal
# `swift test` runs, so it never slows down CI by accident.
#
# Usage: scripts/benchmark-large-files.sh
set -eu
cd "$(dirname "$0")/.."

MODEDIT_BENCHMARK=1 swift test -c release --filter LargeFileBenchmark
