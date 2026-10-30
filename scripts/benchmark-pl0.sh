#!/usr/bin/env bash
set -euo pipefail

# Reproducible release benchmark for the PL/0 lexer and parser engines.
# The Swift suite itself prints one PL0BENCH record per measured operation.
MODEDIT_PL0_BENCHMARK=1 swift test -c release --filter PL0ParserBenchmark
