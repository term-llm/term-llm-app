#!/usr/bin/env python3
"""Write an allowlisted provenance manifest, never a dump of CI environment."""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def main():
    root = Path(os.environ["ARTIFACT_DIR"])
    artifacts = []
    for path in sorted(root.rglob("*")):
        if path.is_file() and path.name != "manifest.json":
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
            artifacts.append(dict(path=str(path.relative_to(root)), bytes=path.stat().st_size, sha256=digest.hexdigest()))
    manifest = dict(
        schema_version=1, label="DEMO FIXTURE · LOCAL", fixture=True,
        limitations=["Synthetic local Hub protocol data; no production credentials or Hub process",
                     "Chat is labelled static HTTP HTML, not upstream chat frontend or model execution",
                     "No real installation/distribution, contain, tunnel, redirect service, or passkey pairing exercised"],
        protocol_repository="SamSaffron/term-llm", protocol_commit="2496b5fddebdc9369642d062fa87b98cd649d415",
        checked_out_commit=git("rev-parse", "HEAD"), dirty_worktree=bool(git("status", "--porcelain")),
        started_at=os.environ["CAPTURE_STARTED_AT"], finished_at=datetime.now(timezone.utc).isoformat(),
        exit_status=int(os.environ["CAPTURE_EXIT_STATUS"]), simulator_udid=os.environ["SIMULATOR_UDID"],
        ci={key: os.environ.get(key, "") for key in ["GITHUB_REPOSITORY", "GITHUB_SHA", "GITHUB_REF", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_EVENT_NAME"]},
        artifacts=artifacts)
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
