"""Offline SwiftBar tests: no GitHub requests or service changes."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "runner_menu", Path(__file__).resolve().parents[1] / "swiftbar/term-llm-ci.1m.py")


def load_menu(repository=None):
    with patch.dict(os.environ):
        if repository is None:
            os.environ.pop("TERM_LLM_CI_REPO", None)
        else:
            os.environ["TERM_LLM_CI_REPO"] = repository
        module = importlib.util.module_from_spec(SPEC)
        SPEC.loader.exec_module(module)
        return module


menu = load_menu()


class SwiftBarTests(unittest.TestCase):
    def test_current_repository_is_default(self):
        self.assertEqual(menu.REPO, "SamSaffron/term-llm-app")
        self.assertEqual(menu.ACTIONS_URL, "https://github.com/SamSaffron/term-llm-app/actions")

    def test_repository_override_applies_to_api_and_all_github_links(self):
        plugin = load_menu("term-llm/term-llm-app")
        with patch.object(plugin.shutil, "which", return_value="/opt/homebrew/bin/gh"), patch.object(
                plugin, "command", return_value=subprocess.CompletedProcess([], 0, stdout="{}")) as run:
            plugin.github("actions/runners")
            plugin.github("actions/runs?per_page=5")
        self.assertEqual([call.args[0] for call in run.call_args_list], [
            ["/opt/homebrew/bin/gh", "api", "repos/term-llm/term-llm-app/actions/runners"],
            ["/opt/homebrew/bin/gh", "api", "repos/term-llm/term-llm-app/actions/runs?per_page=5"]])
        text = plugin.render(None, [{"id": 123, "name": "Build", "conclusion": "success"}], "Running")
        for path in ("actions", "actions/runs/123", "settings/actions/runners"):
            self.assertIn("href=https://github.com/term-llm/term-llm-app/" + path, text)
        self.assertNotIn(menu.DEFAULT_REPO, text)

    def test_invalid_repository_override_fails_closed_without_requests_or_links(self):
        for repository in ("", " ", "term-llm", "term-llm/app/extra", "/app", "owner/",
                           "https://github.com/term-llm/app", "owner/repo?query", "owner/repo#fragment",
                           "owner/repo | bash=bad", "owner/repo\n---", "owner/repo%2Fextra",
                           "owner/..", "owner/.", "-owner/repo", "owner-/repo", "own--er/repo",
                           "a" * 40 + "/repo", "owner/" + "a" * 101, "øwner/repo"):
            with self.subTest(repository=repository):
                plugin = load_menu(repository)
                self.assertIsNone(plugin.REPO)
                with patch.object(plugin, "command") as run, patch.object(
                        plugin, "local_service", return_value="Running"), patch(
                        "sys.argv", ["plugin"]), patch("builtins.print") as output:
                    self.assertEqual(plugin.main(), 0)
                run.assert_not_called()
                text = output.call_args.args[0]
                self.assertIn("Invalid TERM_LLM_CI_REPO", text)
                self.assertNotIn("href=", text)
                self.assertIn("Local service: Running", text)

    def test_repository_validation_allows_normal_github_names(self):
        for repository in ("a/b", "SamSaffron/term-llm-app", "term-llm/.github", "org/repo_name.v2"):
            with self.subTest(repository=repository):
                self.assertEqual(load_menu(repository).REPO, repository)

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
