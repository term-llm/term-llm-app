"""Offline SwiftBar tests: no GitHub requests or service changes."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "runner_menu", Path(__file__).resolve().parents[1] / "swiftbar/term-llm-ci.1m.py")
menu = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(menu)


class SwiftBarTests(unittest.TestCase):
    def test_idle_busy_offline_unknown_are_distinct(self):
        for runner, title in [({"status": "online", "busy": False}, "CI 🟢"),
                              ({"status": "online", "busy": True}, "CI 🟠"),
                              ({"status": "offline"}, "CI 🔴"), (None, "CI ⚠️")]:
            with self.subTest(title=title):
                self.assertEqual(menu.render(runner, [], "Running").splitlines()[0], title)

    def test_run_titles_cannot_inject_actions(self):
        text = menu.render(None, [{"id": 123, "name": "evil\n---\nname | bash=bad",
                                   "head_branch": "branch | terminal=true", "conclusion": "success"}], "Stopped")
        line = next(line for line in text.splitlines() if "evil" in line)
        self.assertEqual(line.count("|"), 1)
        self.assertIn("href=" + menu.ACTIONS_URL + "/runs/123", line)
        self.assertNotIn("\nname", text)

    def test_api_failure_does_not_claim_runner_is_offline(self):
        with patch.object(menu, "github", return_value=None), patch.object(menu, "local_service", return_value="Running"), patch("sys.argv", ["plugin"]), patch("builtins.print") as output:
            self.assertEqual(menu.main(), 0)
        self.assertIn("CI ⚠️", output.call_args.args[0])
        self.assertIn("Local service: Running", output.call_args.args[0])

    def test_no_service_controls_until_installed(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(menu, "RUNNER_DIR", Path(temp)):
            self.assertNotIn("param2=--start", menu.render(None, [], "Not registered"))
            (Path(temp) / ".service").touch()
            self.assertIn("param2=--start", menu.render(None, [], "Stopped"))

    def test_cancel_stop_does_not_touch_service(self):
        with patch.object(menu, "command", return_value=subprocess.CompletedProcess([], 1)) as run:
            self.assertEqual(menu.control("--stop"), 0)
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.args[0][0], "/usr/bin/osascript")

    def test_start_only_invokes_existing_service(self):
        with patch.object(menu, "command", return_value=subprocess.CompletedProcess([], 0)) as run:
            self.assertEqual(menu.control("--start"), 0)
        run.assert_called_once_with(["/bin/bash", "./svc.sh", "start"], cwd=str(menu.RUNNER_DIR))

    def test_unknown_action_rejected(self):
        with patch.object(menu, "command") as run:
            self.assertEqual(menu.control("--install"), 2)
        run.assert_not_called()

    def test_network_timeout_is_nonfatal(self):
        with patch.object(menu.shutil, "which", return_value="/opt/homebrew/bin/gh"), patch.object(menu, "command", side_effect=subprocess.TimeoutExpired("gh", 10)):
            self.assertIsNone(menu.github("actions/runners"))


if __name__ == "__main__":
    unittest.main()
