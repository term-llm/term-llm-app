#!/usr/bin/env python3
# <xbar.title>term-llm CI</xbar.title>
# <xbar.version>1.0</xbar.version>
# <xbar.desc>Local GitHub runner status and controls; never dispatches CI jobs.</xbar.desc>
# <xbar.dependencies>python3,gh</xbar.dependencies>
"""SwiftBar plugin. Python 3.9+; standard library only."""
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
from datetime import datetime

DEFAULT_REPO = "SamSaffron/term-llm-app"


def configured_repository():
    # Set TERM_LLM_CI_REPO after an app-repository transfer. Do not silently
    # query the old repository when an override is malformed (including empty).
    value = os.environ.get("TERM_LLM_CI_REPO", DEFAULT_REPO)
    parts = value.split("/")
    if len(parts) != 2:
        return None
    owner, repo = parts
    if (not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?", owner)
            or "--" in owner or repo in (".", "..")
            or not re.fullmatch(r"[A-Za-z0-9_.-]{1,100}", repo)):
        return None
    return value


REPO = configured_repository()
RUNNER_NAME = "term-llm-macbook"
RUNNER_DIR = Path.home() / "actions-runner-term-llm"
ACTIONS_URL = "https://github.com/" + REPO + "/actions" if REPO else None


def clean(value):
    # Repository-controlled titles must not inject SwiftBar actions or menu lines.
    return " ".join(str(value).replace("|", "¦").split())[:160]


def command(args, timeout=10, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout, **kwargs)


def github(endpoint):
    if REPO is None:
        return None
    gh = shutil.which("gh")
    if not gh:
        gh = next((p for p in ("/opt/homebrew/bin/gh", "/usr/local/bin/gh")
                   if Path(p).is_file()), None)
    if not gh:
        return None
    try:
        result = command([gh, "api", "repos/" + REPO + "/" + endpoint],
                         env=dict(os.environ, GH_PROMPT_DISABLED="1"))
        return json.loads(result.stdout) if result.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return None


def local_service():
    if not (RUNNER_DIR / ".runner").is_file():
        return "Not registered"
    try:
        plist = Path((RUNNER_DIR / ".service").read_text().strip())
        with plist.open("rb") as source:
            label = plistlib.load(source)["Label"]
        result = command(["/bin/launchctl", "print", "gui/{}/{}".format(os.getuid(), label)])
        if result.returncode == 0:
            return "Running" if "state = running" in result.stdout else "Loaded, not running"
        return "Stopped"
    except (OSError, ValueError, KeyError, subprocess.TimeoutExpired, plistlib.InvalidFileException):
        return "Service not installed"


def action(label, argument):
    return "{} | bash={} param1={} param2={} terminal=false refresh=true".format(
        label, shlex.quote(sys.executable), shlex.quote(str(Path(__file__).resolve())), argument)


def open_folder(label, path):
    return "{} | bash=/usr/bin/open param1={} terminal=false".format(label, shlex.quote(str(path)))


def render(runner, runs, service):
    if REPO is None:
        title = "CI ⚠️"
        status = "Invalid TERM_LLM_CI_REPO — expected owner/repository"
        runs = None
    elif runner is None:
        title = "CI ⚠️"
        status = "GitHub status unavailable — check network / gh authentication"
    elif runner.get("status") != "online":
        title, status = "CI 🔴", "Runner offline — jobs wait; no hosted fallback"
    elif runner.get("busy"):
        title, status = "CI 🟠", "Runner online · busy"
    else:
        title, status = "CI 🟢", "Runner online · idle"
    lines = [title, "---", "term-llm · MacBook CI", status,
             "Local service: " + clean(service), "---", "Recent repository runs"]
    if runs is None:
        lines.append("Run history unavailable")
    elif not runs:
        lines.append("No recent runs")
    else:
        for run in runs:
            state = run.get("conclusion") or run.get("status", "unknown")
            icon = {"success": "✅", "failure": "❌", "in_progress": "🟠",
                    "queued": "⏳", "cancelled": "◻️"}.get(state, "•")
            name = clean(run.get("name") or run.get("display_title") or "Run")
            branch = clean(run.get("head_branch", ""))
            run_id = run.get("id")
            if not isinstance(run_id, int):
                continue
            lines.append("{} {} · {} · {} | href={}/runs/{}".format(
                icon, name, branch, clean(state), ACTIONS_URL, run_id))
    lines += ["---"]
    if REPO:
        lines += ["Open GitHub Actions | href=" + ACTIONS_URL,
                  "Runner settings | href=https://github.com/" + REPO + "/settings/actions/runners"]
    lines += [open_folder("Open runner diagnostic logs", RUNNER_DIR / "_diag"),
              open_folder("Open runner folder", RUNNER_DIR)]
    if (RUNNER_DIR / ".service").is_file():
        lines += ["---", action("Start runner service", "--start"),
                  action("Stop runner service…", "--stop")]
    lines += ["---", "Refresh now | refresh=true",
              "Updated " + datetime.now().strftime("%H:%M:%S") + " · refreshes every minute"]
    return "\n".join(lines)


def control(argument):
    # No registration, installation, CI dispatch, or arbitrary command actions.
    if argument not in ("--start", "--stop"):
        return 2
    if argument == "--stop":
        prompt = command(["/usr/bin/osascript", "-e",
                          'display dialog "Stop the local CI runner? This may interrupt a running job. '
                          'New jobs will wait until it is started again." with title "term-llm CI" '
                          'buttons {"Cancel", "Stop runner"} default button "Cancel" cancel button "Cancel"'], timeout=120)
        if prompt.returncode != 0:
            return 0
    result = command(["/bin/bash", "./svc.sh", argument[2:]], cwd=str(RUNNER_DIR))
    if result.returncode:
        # Avoid exposing raw command output or tokens in a notification.
        command(["/usr/bin/osascript", "-e",
                 'display alert "Runner service action failed" message '
                 '"Check the runner folder and service status in Terminal."'])
    return result.returncode


def main():
    if len(sys.argv) > 1:
        return control(sys.argv[1])
    data = github("actions/runners")
    runner = None
    if isinstance(data, dict) and isinstance(data.get("runners"), list):
        runner = next((r for r in data["runners"] if r.get("name") == RUNNER_NAME),
                      {"status": "offline"})
    data = github("actions/runs?per_page=5")
    runs = data.get("workflow_runs") if isinstance(data, dict) else None
    print(render(runner, runs, local_service()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
