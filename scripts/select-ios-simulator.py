#!/usr/bin/env python3
"""Select an already available iPhone simulator; never create/download one."""
import argparse
import json
import re
import subprocess
import sys
import uuid


def select_device(document):
    candidates = []
    for runtime, devices in document.get("devices", {}).items():
        match = re.search(r"\.iOS-(\d+(?:-\d+)*)$", runtime)
        if not match:
            continue
        version = tuple(int(part) for part in match.group(1).split("-"))
        version = (version + (0, 0, 0))[:3]
        if version < (17, 0, 0):
            continue
        for device in devices:
            if device.get("isAvailable") is not True or not device.get("name", "").startswith("iPhone"):
                continue
            if not device.get("deviceTypeIdentifier", "").startswith("com.apple.CoreSimulator.SimDeviceType.iPhone-"):
                continue
            try:
                udid = str(uuid.UUID(device["udid"]))
            except (ValueError, KeyError, TypeError, AttributeError):
                continue
            # Highest iOS, then lexical model/UUID; JSON iteration order is irrelevant.
            candidates.append((tuple(-part for part in version), device["name"], udid))
    if not candidates:
        raise ValueError("No already available iPhone simulator with iOS >=17; no runtime will be provisioned")
    return sorted(candidates)[0][2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", help="Read saved simctl JSON for offline testing instead of invoking xcrun")
    options = parser.parse_args()
    if options.input:
        with open(options.input, encoding="utf-8") as stream:
            document = json.load(stream)
    else:
        document = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))
    try:
        print(select_device(document))
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
