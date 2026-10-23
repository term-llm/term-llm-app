#!/usr/bin/env python3
"""Check all requested unit suites actually exist in xcresult, not just exit 0."""
import json
from pathlib import Path
import sys

SUITES = ("HubClientTests", "HubStoreTests", "HubPasskeyTests")


def verify_units(directory, suites=SUITES, *, summary_file="unit-test-summary.json", tree_file="unit-test-tree.json"):
    root = Path(directory)
    summary = json.loads((root / summary_file).read_text())
    if (summary.get("result") != "Passed" or summary.get("passedTests", 0) < len(suites)
            or summary.get("failedTests", 0) != 0 or summary.get("skippedTests", 0) != 0):
        raise ValueError("Expected executed, passing, non-skipped Hub unit regressions")
    tree = json.loads((root / tree_file).read_text())
    def nodes(value):
        for node in value:
            yield node
            yield from nodes(node.get("children", []))

    all_nodes = list(nodes(tree.get("testNodes", [])))
    missing = []
    for suite in suites:
        matches = [node for node in all_nodes if node.get("name") == suite
                   and node.get("nodeType") == "Test Suite" and node.get("result") == "Passed"]
        if not any(any(child.get("nodeType") == "Test Case" and child.get("result") == "Passed"
                       for child in nodes(match.get("children", []))) for match in matches):
            missing.append(suite)
    if missing:
        raise ValueError(f"Requested unit suites absent or not executed in xcresult: {missing}")
    print("Validated xcresult unit-suite execution metadata: " + ", ".join(suites))


if __name__ == "__main__":
    try:
        verify_units(sys.argv[1], tuple(sys.argv[2:]) or SUITES)
    except (ValueError, OSError, json.JSONDecodeError) as error:
        raise SystemExit(str(error))
