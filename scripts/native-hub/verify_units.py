#!/usr/bin/env python3
"""Check all requested unit suites actually exist in xcresult, not just exit 0."""
import json
from pathlib import Path
import sys

SUITES = ("HubClientTests", "HubStoreTests", "HubPasskeyTests")


def verify_units(directory):
    root = Path(directory)
    summary = json.loads((root / "unit-test-summary.json").read_text())
    if (summary.get("result") != "Passed" or summary.get("passedTests", 0) < len(SUITES)
            or summary.get("failedTests", 0) != 0 or summary.get("skippedTests", 0) != 0):
        raise ValueError("Expected executed, passing, non-skipped Hub unit regressions")
    tree = json.loads((root / "unit-test-tree.json").read_text())
    def nodes(value):
        for node in value:
            yield node
            yield from nodes(node.get("children", []))

    all_nodes = list(nodes(tree.get("testNodes", [])))
    missing = []
    for suite in SUITES:
        matches = [node for node in all_nodes if node.get("name") == suite
                   and node.get("nodeType") == "Test Suite" and node.get("result") == "Passed"]
        if not any(any(child.get("nodeType") == "Test Case" and child.get("result") == "Passed"
                       for child in nodes(match.get("children", []))) for match in matches):
            missing.append(suite)
    if missing:
        raise ValueError(f"Requested unit suites absent or not executed in xcresult: {missing}")
    print("Validated xcresult unit-suite execution metadata: " + ", ".join(SUITES))


if __name__ == "__main__":
    try:
        verify_units(sys.argv[1])
    except (ValueError, OSError, json.JSONDecodeError) as error:
        raise SystemExit(str(error))
