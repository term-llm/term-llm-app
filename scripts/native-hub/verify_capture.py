#!/usr/bin/env python3
"""Fail closed on missing test execution, HTTP exercise, screenshots, or MP4."""
import json
import os
from pathlib import Path
import sys

REQUIRED_ROUTES = {"/", "/api/nodes", "/api/attention", "/api/delegations", "/api/auth/session",
                   "/api/auth/credentials", "/api/registration-info", "/node/dev/chat/2", "/node/stalled/chat/3"}


def verify(directory, simulator_udid=None, *, required_routes=REQUIRED_ROUTES,
           stalled_path="/node/stalled/chat/3", refresh_path="/api/nodes",
           min_pngs=8, video_filename="native-hub-demo-fixture.mp4"):
    root = Path(directory)
    summary = json.loads((root / "test-summary.json").read_text())
    if summary.get("passedTests", 0) < 1 or summary.get("failedTests", 0) != 0 or summary.get("skippedTests", 0) != 0:
        raise ValueError("Expected executed, passing, non-skipped XCUITest journey")
    if summary.get("result") != "Passed":
        raise ValueError("xcresult does not report Passed")
    if simulator_udid:
        tested_devices = {entry.get("device", {}).get("deviceId", "").lower()
                          for entry in summary.get("devicesAndConfigurations", [])}
        if tested_devices != {simulator_udid.lower()}:
            raise ValueError(f"Tests must run on the recorded simulator, not a clone: {tested_devices}")
    requests = [json.loads(line) for line in (root / "fixture-requests.jsonl").read_text().splitlines()]
    observed = {item["path"] for item in requests if item["status"] in (200, "stalled")}
    missing = required_routes - observed
    if missing:
        raise ValueError(f"Native/browser HTTP coverage missing: {sorted(missing)}")
    stalled_index = next((index for index, item in enumerate(requests)
                           if item["path"] == stalled_path and item["status"] == "stalled"), None)
    if stalled_index is None:
        raise ValueError("No genuine stalled HTTP navigation observed")
    after_stall = requests[stalled_index + 1:]
    # A response after the slow request has completed does not prove concurrency.
    # Stop at its first terminal response; do not accidentally accept later polls.
    terminal = next((index for index, item in enumerate(after_stall)
                     if item["path"] == stalled_path and isinstance(item["status"], int)), len(after_stall))
    if not any(item["path"] == refresh_path and item["status"] == 200 for item in after_stall[:terminal]):
        raise ValueError("No native dashboard HTTP refresh while stalled request remained pending")
    pngs = list((root / "screenshots").rglob("*.png"))
    if len(pngs) < min_pngs:
        raise ValueError(f"Need at least {min_pngs} actual journey screenshots, found {len(pngs)}")
    for png in pngs:
        with png.open("rb") as stream:
            if stream.read(8) != b"\x89PNG\r\n\x1a\n":
                raise ValueError(f"Not a PNG: {png.name}")
    video = root / video_filename
    # simctl writes its moov metadata only after recording is finalized.
    boxes = set()
    length = video.stat().st_size
    with video.open("rb") as stream:
        while stream.tell() < length:
            start = stream.tell()
            header = stream.read(8)
            if len(header) != 8:
                raise ValueError("Truncated MP4 box header")
            size, kind = int.from_bytes(header[:4], "big"), header[4:8]
            header_size = 8
            if size == 1:
                extended = stream.read(8)
                if len(extended) != 8:
                    raise ValueError("Truncated MP4 extended size")
                size, header_size = int.from_bytes(extended, "big"), 16
            elif size == 0:
                size = length - start
            if size < header_size or start + size > length:
                raise ValueError("Invalid/truncated MP4 box")
            boxes.add(kind)
            stream.seek(start + size)
    if not {b"ftyp", b"moov", b"mdat"}.issubset(boxes) or length < 10000:
        raise ValueError("Missing/unfinalized simulator MP4")
    print(f"Validated result metadata, {len(pngs)} PNG headers, finalized MP4 boxes, and HTTP route coverage")


if __name__ == "__main__":
    try:
        verify(sys.argv[1], os.environ["SIMULATOR_UDID"])
    except (ValueError, OSError, KeyError, json.JSONDecodeError) as error:
        raise SystemExit(str(error))
