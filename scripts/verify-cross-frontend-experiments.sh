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

swift run --package-path "$modedit_root" modedit-experiment \
    product-campaign "$report_dir/modedit-product.json"
swift run --package-path "$ecosystem_root/Grammar-REPL" \
    grammar-repl-pl0-experiment product-campaign "$report_dir/grammar-repl-product.json"
swift run --package-path "$ecosystem_root/Grammar-Workbench" \
    grammar-workbench-pl0-experiment product-campaign "$report_dir/grammar-workbench-product.json"
swift run --package-path "$ecosystem_root/Incremental-Parsing" incremental-report compare \
    "$report_dir/modedit-product.json" \
    "$report_dir/grammar-repl-product.json" \
    "$report_dir/grammar-workbench-product.json"
swift run --package-path "$modedit_root" modedit-experiment \
    product-budgets "$report_dir/pl0-product-budgets.json"
for report in modedit-product grammar-repl-product grammar-workbench-product; do
    swift run --package-path "$ecosystem_root/Incremental-Parsing" incremental-report gate \
        "$report_dir/$report.json" "$report_dir/pl0-product-budgets.json"
done

echo "Cross-front-end reports: $report_dir"
