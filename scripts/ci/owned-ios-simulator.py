#!/usr/bin/env python3
"""Create, boot, and safely delete one job-owned iOS simulator."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import uuid


NAME_PREFIX = "term-llm-ci-"
MARKER_VERSION = 1
MINIMUM_IOS = (17, 0, 0)


def _runtime_version(identifier):
    match = re.fullmatch(r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-(\d+(?:-\d+)*)", identifier or "")
    if not match:
        return None
    version = tuple(int(part) for part in match.group(1).split("-"))
    return (version + (0, 0, 0))[:3]


def select_configuration(runtimes_document, devices_document):
    """Return a deterministic installed (device type, runtime) pair."""
    available_runtimes = {}
    for runtime in runtimes_document.get("runtimes", []):
        identifier = runtime.get("identifier")
        version = _runtime_version(identifier)
        if runtime.get("isAvailable") is True and version is not None and version >= MINIMUM_IOS:
            available_runtimes[identifier] = version

    candidates = []
    for runtime_identifier, devices in devices_document.get("devices", {}).items():
        version = available_runtimes.get(runtime_identifier)
        if version is None:
            continue
        for device in devices:
            name = device.get("name", "")
            device_type = device.get("deviceTypeIdentifier", "")
            if device.get("isAvailable") is not True or not name.startswith("iPhone"):
                continue
            if not re.fullmatch(r"com\.apple\.CoreSimulator\.SimDeviceType\.iPhone-[A-Za-z0-9-]+", device_type):
                continue
            candidates.append((tuple(-part for part in version), name, device_type, runtime_identifier))

    if not candidates:
        raise ValueError("No installed available iPhone device type and iOS >=17 runtime; nothing will be provisioned")
    _, _, device_type, runtime_identifier = sorted(candidates)[0]
    return device_type, runtime_identifier


def _validate_name(name):
    if not re.fullmatch(r"term-llm-ci-[A-Za-z0-9._-]{1,96}", name):
        raise ValueError(f"Simulator name must use the {NAME_PREFIX!r} job prefix and safe tag characters")


def _validate_udid(value):
    candidate = value.strip()
    if not re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", candidate):
        raise ValueError("simctl create did not return exactly one valid simulator UUID")
    try:
        uuid.UUID(candidate)
    except (ValueError, TypeError, AttributeError) as error:
        raise ValueError("simctl create did not return exactly one valid simulator UUID") from error
    return candidate


def _write_marker(state_file, marker, exclusive=False):
    state_file = Path(state_file)
    payload = (json.dumps(marker, sort_keys=True) + "\n").encode("utf-8")
    flags = os.O_WRONLY | os.O_CREAT | (os.O_EXCL if exclusive else os.O_TRUNC)
    descriptor = os.open(state_file, flags, 0o600)
    try:
        os.write(descriptor, payload)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def create_owned(name, state_file, check_output=subprocess.check_output, check_call=subprocess.check_call):
    """Create and boot one simulator, recording its returned UUID before booting."""
    _validate_name(name)
    state_file = Path(state_file)
    if state_file.exists():
        raise ValueError(f"Ownership marker already exists: {state_file}")

    runtimes = json.loads(check_output(
        ["xcrun", "simctl", "list", "runtimes", "available", "--json"], text=True
    ))
    devices = json.loads(check_output(
        ["xcrun", "simctl", "list", "devices", "available", "--json"], text=True
    ))
    device_type, runtime = select_configuration(runtimes, devices)
    created = check_output(["xcrun", "simctl", "create", name, device_type, runtime], text=True)
    udid = _validate_udid(created)
    try:
        _write_marker(state_file, {
            "markerVersion": MARKER_VERSION,
            "name": name,
            "phase": "created",
            "udid": udid,
        }, exclusive=True)
    except OSError:
        # The UUID came directly from this create call, so rollback cannot touch shared inventory.
        check_call(["xcrun", "simctl", "delete", udid], stdout=sys.stderr)
        raise

    check_call(["xcrun", "simctl", "boot", udid], stdout=sys.stderr)
    check_call(["xcrun", "simctl", "bootstatus", udid, "-b"], stdout=sys.stderr)
    return udid


def _read_marker(state_file):
    marker = json.loads(Path(state_file).read_text(encoding="utf-8"))
    if marker.get("markerVersion") != MARKER_VERSION:
        raise ValueError("Unrecognized simulator ownership marker")
    _validate_name(marker.get("name", ""))
    marker["udid"] = _validate_udid(marker.get("udid", ""))
    if marker.get("phase") not in {"created", "cleaned"}:
        raise ValueError("Invalid simulator ownership marker phase")
    return marker


def cleanup_owned(state_file, check_output=subprocess.check_output, check_call=subprocess.check_call):
    """Delete only the simulator identified and named by this job's marker."""
    state_file = Path(state_file)
    if not state_file.exists():
        return False
    marker = _read_marker(state_file)
    if marker["phase"] == "cleaned":
        return False

    document = json.loads(check_output(["xcrun", "simctl", "list", "devices", "--json"], text=True))
    matches = [device for devices in document.get("devices", {}).values() for device in devices
               if device.get("udid") == marker["udid"]]
    if len(matches) > 1:
        raise ValueError("Owned simulator UUID appears more than once")
    if matches:
        device = matches[0]
        if device.get("name") != marker["name"]:
            raise ValueError("Owned simulator UUID no longer has the job-tagged name; refusing cleanup")
        if device.get("state") != "Shutdown":
            check_call(["xcrun", "simctl", "shutdown", marker["udid"]], stdout=sys.stderr)
        check_call(["xcrun", "simctl", "delete", marker["udid"]], stdout=sys.stderr)

    marker["phase"] = "cleaned"
    _write_marker(state_file, marker)
    return bool(matches)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("create", help="Create and boot one owned simulator")
    create.add_argument("--name", required=True)
    create.add_argument("--state-file", required=True)
    cleanup = commands.add_parser("cleanup", help="Delete only the simulator in an ownership marker")
    cleanup.add_argument("--state-file", required=True)
    options = parser.parse_args()

    try:
        if options.command == "create":
            print(create_owned(options.name, options.state_file))
        else:
            cleanup_owned(options.state_file)
    except (ValueError, OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
