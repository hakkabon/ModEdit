#!/bin/sh
set -eu

modedit_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ecosystem_root=$(dirname -- "$modedit_root")
report_dir=$(mktemp -d /tmp/pl0-cross-frontend.XXXXXX)

swift run --package-path "$modedit_root" modedit-experiment "$report_dir/modedit.json"
swift run --package-path "$ecosystem_root/Grammar-REPL" grammar-repl-pl0-experiment "$report_dir/grammar-repl.json"
swift run --package-path "$ecosystem_root/Grammar-Workbench" grammar-workbench-pl0-experiment "$report_dir/grammar-workbench.json"
swift run --package-path "$modedit_root" modedit-experiment compare \
    "$report_dir/modedit.json" \
    "$report_dir/grammar-repl.json" \
    "$report_dir/grammar-workbench.json"

echo "Cross-front-end reports: $report_dir"
