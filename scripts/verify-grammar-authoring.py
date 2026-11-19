#!/usr/bin/env python3
"""Check the grammar-authoring trial through both command-line consumers."""
import argparse
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--repl", required=True, type=Path)
parser.add_argument("--workbench", required=True, type=Path)
options = parser.parse_args()
fixture = Path(__file__).resolve().parent.parent / "Examples" / "FeatureFlags"
corpus = fixture / "Examples.json"


def check(executable, grammar, expected_exit):
    result = subprocess.run(
        [str(executable.resolve()), "authoring-check", str(grammar), str(corpus)],
        capture_output=True, text=True, check=False,
    )
    if result.returncode != expected_exit:
        raise RuntimeError(f"{executable.name} exited {result.returncode}: {result.stderr}")
    report = json.loads(result.stdout)
    if report["passed"] != (expected_exit == 0):
        raise RuntimeError(f"{executable.name} reported the wrong outcome")
    return {
        "grammarValid": report["grammarValid"],
        "diagnostics": report["diagnostics"],
        "examples": [
            {key: example.get(key) for key in ("id", "status", "passed", "tree")}
            for example in report["examples"]
        ],
    }


for name, expected_exit in [
    ("FeatureFlags.bnf", 0),
    ("Drafts/RemoveDisable.bnf", 1),
    ("Drafts/IncompleteAction.bnf", 1),
    ("FeatureFlags.bnf", 0),
]:
    repl = check(options.repl, fixture / name, expected_exit)
    workbench = check(options.workbench, fixture / name, expected_exit)
    if repl != workbench:
        raise RuntimeError(f"Consumers disagree on {name}")
    print(f"Verified {name}")
