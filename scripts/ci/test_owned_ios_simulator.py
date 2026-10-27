#!/usr/bin/env python3
"""Portable tests for the owned iOS simulator lifecycle; xcrun is always mocked."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("owned-ios-simulator.py")
spec = importlib.util.spec_from_file_location("owned_ios_simulator", SCRIPT)
owned = importlib.util.module_from_spec(spec)
spec.loader.exec_module(owned)


RUNTIME_17 = "com.apple.CoreSimulator.SimRuntime.iOS-17-5"
RUNTIME_26 = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
TYPE_16 = "com.apple.CoreSimulator.SimDeviceType.iPhone-16"
TYPE_16_PRO = "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
UDID = "2911FD29-A09E-4A81-BEA7-99A616FB7FC8"
NAME = "term-llm-ci-12345-2-simulator"


def runtime(identifier, available=True):
    return {"identifier": identifier, "isAvailable": available}


def device(name, device_type, available=True, udid=UDID, state="Shutdown"):
    return {
        "name": name,
        "deviceTypeIdentifier": device_type,
        "isAvailable": available,
        "udid": udid,
        "state": state,
    }


class SimulatorConfigurationTests(unittest.TestCase):
    def test_selects_latest_available_ios_and_stable_iphone_type(self):
        runtimes = {"runtimes": [runtime(RUNTIME_17), runtime(RUNTIME_26)]}
        devices = {"devices": {
            RUNTIME_17: [device("iPhone 16", TYPE_16)],
            RUNTIME_26: [device("iPhone 16 Pro", TYPE_16_PRO), device("iPhone 16", TYPE_16)],
        }}
        expected = (TYPE_16, RUNTIME_26)
        self.assertEqual(owned.select_configuration(runtimes, devices), expected)
        devices["devices"] = dict(reversed([
            (key, list(reversed(value))) for key, value in devices["devices"].items()
        ]))
        self.assertEqual(owned.select_configuration(runtimes, devices), expected)

    def test_rejects_old_unavailable_and_non_iphone_inventory(self):
        ipad_type = "com.apple.CoreSimulator.SimDeviceType.iPad-Pro"
        cases = [
            ({"runtimes": [runtime("com.apple.CoreSimulator.SimRuntime.iOS-16-4")]},
             {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-16-4": [device("iPhone 14", TYPE_16)]}}),
            ({"runtimes": [runtime(RUNTIME_26, False)]},
             {"devices": {RUNTIME_26: [device("iPhone 16", TYPE_16)]}}),
            ({"runtimes": [runtime(RUNTIME_26)]},
             {"devices": {RUNTIME_26: [device("iPad Pro", ipad_type), device("iPhone 16", TYPE_16, False)]}}),
        ]
        for runtimes, devices in cases:
            with self.subTest(runtimes=runtimes, devices=devices):
                with self.assertRaisesRegex(ValueError, "No installed available iPhone"):
                    owned.select_configuration(runtimes, devices)


class OwnedSimulatorLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.marker = Path(self.temporary.name) / "owned.json"
        self.output_calls = []
        self.action_calls = []

    def inventory_output(self, command, text=False):
        self.output_calls.append(command)
        self.assertTrue(text)
        if command[3] == "runtimes":
            return json.dumps({"runtimes": [runtime(RUNTIME_26)]})
        if command[3] == "devices":
            return json.dumps({"devices": {RUNTIME_26: [device("iPhone 16", TYPE_16)]}})
        if command[2] == "create":
            return UDID + "\n"
        self.fail(f"Unexpected output command: {command}")

    def action(self, command, **kwargs):
        self.assertIs(kwargs.get("stdout"), owned.sys.stderr)
        self.action_calls.append(command)

    def write_marker(self, phase="created"):
        self.marker.write_text(json.dumps({
            "markerVersion": owned.MARKER_VERSION,
            "name": NAME,
            "phase": phase,
            "udid": UDID,
        }), encoding="utf-8")

    def test_create_records_returned_uuid_before_boot_and_waits_for_bootstatus(self):
        result = owned.create_owned(NAME, self.marker, self.inventory_output, self.action)
        self.assertEqual(result, UDID)
        self.assertEqual(self.output_calls, [
            ["xcrun", "simctl", "list", "runtimes", "available", "--json"],
            ["xcrun", "simctl", "list", "devices", "available", "--json"],
            ["xcrun", "simctl", "create", NAME, TYPE_16, RUNTIME_26],
        ])
        self.assertEqual(self.action_calls, [
            ["xcrun", "simctl", "boot", UDID],
            ["xcrun", "simctl", "bootstatus", UDID, "-b"],
        ])
        marker = json.loads(self.marker.read_text(encoding="utf-8"))
        self.assertEqual(marker, {
            "markerVersion": owned.MARKER_VERSION,
            "name": NAME,
            "phase": "created",
            "udid": UDID,
        })
        self.assertEqual(self.marker.stat().st_mode & 0o777, 0o600)

    def test_create_rejects_unsafe_name_without_invoking_xcrun(self):
        with self.assertRaisesRegex(ValueError, "job prefix"):
            owned.create_owned("Sam's iPhone", self.marker, self.inventory_output, self.action)
        self.assertEqual(self.output_calls, [])
        self.assertEqual(self.action_calls, [])

    def test_create_rejects_non_uuid_output_without_booting_or_writing_marker(self):
        def output(command, text=False):
            if command[3] == "runtimes":
                return json.dumps({"runtimes": [runtime(RUNTIME_26)]})
            if command[3] == "devices":
                return json.dumps({"devices": {RUNTIME_26: [device("iPhone 16", TYPE_16)]}})
            return UDID + "\nSIMULATOR_UDID=shared"

        with self.assertRaisesRegex(ValueError, "exactly one valid simulator UUID"):
            owned.create_owned(NAME, self.marker, output, self.action)
        self.assertFalse(self.marker.exists())
        self.assertEqual(self.action_calls, [])

    def test_cleanup_shuts_down_and_deletes_only_marker_uuid(self):
        self.write_marker()
        def output(command, text=False):
            self.output_calls.append(command)
            return json.dumps({"devices": {RUNTIME_26: [device(NAME, TYPE_16, udid=UDID, state="Booted")]}})

        self.assertTrue(owned.cleanup_owned(self.marker, output, self.action))
        self.assertEqual(self.output_calls, [["xcrun", "simctl", "list", "devices", "--json"]])
        self.assertEqual(self.action_calls, [
            ["xcrun", "simctl", "shutdown", UDID],
            ["xcrun", "simctl", "delete", UDID],
        ])
        self.assertEqual(json.loads(self.marker.read_text())["phase"], "cleaned")

    def test_cleanup_of_shutdown_device_skips_shutdown_but_deletes_exact_uuid(self):
        self.write_marker()
        def output(command, text=False):
            return json.dumps({"devices": {RUNTIME_26: [device(NAME, TYPE_16, udid=UDID)]}})

        self.assertTrue(owned.cleanup_owned(self.marker, output, self.action))
        self.assertEqual(self.action_calls, [["xcrun", "simctl", "delete", UDID]])

    def test_cleanup_refuses_uuid_with_a_different_name(self):
        self.write_marker()
        def output(command, text=False):
            return json.dumps({"devices": {RUNTIME_26: [device("Sam's shared iPhone", TYPE_16, udid=UDID, state="Booted")]}})

        with self.assertRaisesRegex(ValueError, "refusing cleanup"):
            owned.cleanup_owned(self.marker, output, self.action)
        self.assertEqual(self.action_calls, [])
        self.assertEqual(json.loads(self.marker.read_text())["phase"], "created")

    def test_cleanup_missing_or_already_cleaned_marker_is_idempotent(self):
        def forbidden(*args, **kwargs):
            self.fail("No xcrun command is allowed without an active ownership marker")
        self.assertFalse(owned.cleanup_owned(self.marker, forbidden, forbidden))
        self.write_marker(phase="cleaned")
        self.assertFalse(owned.cleanup_owned(self.marker, forbidden, forbidden))

    def test_source_contains_no_broad_simulator_mutation(self):
        source = SCRIPT.read_text(encoding="utf-8")
        for forbidden in ["shutdown all", "delete all", "erase all", "--delete-unavailable"]:
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, source)


if __name__ == "__main__":
    unittest.main()
