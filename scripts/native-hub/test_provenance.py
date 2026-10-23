import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import manifest
from verify_units import SUITES, verify_units


class UnitResultGateTests(unittest.TestCase):
    def test_all_unit_suites_must_execute(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "unit-test-summary.json").write_text(json.dumps(dict(
                result="Passed", passedTests=9, failedTests=0, skippedTests=0)))
            tree = root / "unit-test-tree.json"
            suite_nodes = [{"name": name, "nodeType": "Test Suite", "result": "Passed",
                            "children": [{"name": "testExample()", "nodeType": "Test Case", "result": "Passed"}]}
                           for name in SUITES]
            tree.write_text(json.dumps({"testNodes": suite_nodes}))
            verify_units(root)
            tree.write_text(json.dumps({"testNodes": suite_nodes[:1]}))
            with self.assertRaises(ValueError):
                verify_units(root)


class ManifestTests(unittest.TestCase):
    def test_allowlisted_provenance_and_hashes_not_environment_dump(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "test.log").write_text("test log\n")
            environment = dict(ARTIFACT_DIR=temp, CAPTURE_STARTED_AT="2026-10-23T06:00:00Z",
                               CAPTURE_EXIT_STATUS="1", SIMULATOR_UDID="test-device",
                               GITHUB_RUN_ID="123", GITHUB_RUN_ATTEMPT="2",
                               UNRELATED_SECRET="never-dump-this")
            with patch.dict(os.environ, environment, clear=True), patch.object(manifest, "git", side_effect=["abc123", ""]):
                manifest.main()
            text = (root / "manifest.json").read_text()
            data = json.loads(text)
            self.assertEqual(data["checked_out_commit"], "abc123")
            self.assertEqual(data["exit_status"], 1)
            self.assertEqual(data["artifacts"][0]["path"], "test.log")
            self.assertEqual(len(data["artifacts"][0]["sha256"]), 64)
            self.assertNotIn("UNRELATED_SECRET", text)
            self.assertNotIn("never-dump-this", text)
            self.assertTrue(data["fixture"])


if __name__ == "__main__":
    unittest.main()
