#!/usr/bin/env python3
"""Offline unit tests for CI simulator selection; no Apple toolchain invoked."""
import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location("selector", pathlib.Path(__file__).with_name("select-ios-simulator.py"))
selector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selector)


class SimulatorSelectionTests(unittest.TestCase):
    def device(self, name, number, available=True):
        return {"name": name, "udid": f"00000000-0000-4000-8000-{number:012d}", "isAvailable": available,
                "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType." + ("iPhone-16" if name.startswith("iPhone") else "iPad-Pro")}

    def test_latest_available_iphone_and_stable_order(self):
        older = self.device("iPhone 16", 1)
        selected = self.device("iPhone 16", 2)
        sibling = self.device("iPhone 16 Pro", 3)
        unavailable = self.device("iPhone 17", 4, False)
        entries = {
            "com.apple.CoreSimulator.SimRuntime.iOS-17-5": [older],
            "com.apple.CoreSimulator.SimRuntime.iOS-18-2": [sibling, unavailable, selected],
            "com.apple.CoreSimulator.SimRuntime.tvOS-19-0": [self.device("iPhone 19", 9)],
        }
        first = selector.select_device({"devices": entries})
        self.assertEqual(first, selected["udid"])
        reversed_entries = {key: list(reversed(value)) for key, value in reversed(list(entries.items()))}
        self.assertEqual(selector.select_device({"devices": reversed_entries}), first)

    def test_preserves_actual_xcode_destination_uuid_case(self):
        for udid in [
            "2911FD29-A09E-4A81-BEA7-99A616FB7FC8",
            "2911Fd29-a09E-4a81-bEa7-99a616fB7fc8",
        ]:
            with self.subTest(udid=udid):
                device = self.device("iPhone 16", 1)
                device["udid"] = udid
                document = {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-2": [device]}}
                self.assertEqual(selector.select_device(document), udid)

    def test_ignores_ipad_old_unavailable_and_invalid_ids(self):
        invalid = self.device("iPhone 16", 1)
        invalid["udid"] = "invalid\nSIMULATOR_UDID=unsafe"
        for document in [
            {"devices": {}},
            {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-16-4": [self.device("iPhone 14", 1)]}},
            {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-18-0": [self.device("iPad Pro", 2), invalid, self.device("iPhone 16", 3, False)]}},
        ]:
            with self.assertRaisesRegex(ValueError, "No already available iPhone"):
                selector.select_device(document)


if __name__ == "__main__":
    unittest.main()
