#!/usr/bin/env python3
"""Offline tests for the license notice check; no Xcode build or network."""
import importlib.util
import pathlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "license_check", pathlib.Path(__file__).resolve().with_name("check-license-notices.py"))
license_check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(license_check)


class LicenseNoticeTests(unittest.TestCase):
    def test_repository_notices_are_current(self):
        self.assertEqual(license_check.verify(), [])

    def test_render_reproduces_every_recorded_text_verbatim(self):
        sources = license_check.load_sources()
        rendered = license_check.render(sources)
        self.assertEqual(rendered, license_check.NOTICES.read_text(encoding="utf-8"))
        for component in sources["components"]:
            text = (license_check.ROOT / component["licenseFile"]).read_text(encoding="utf-8")
            with self.subTest(component=component["id"]):
                self.assertIn(text.rstrip("\n"), rendered)

    def test_every_target_copies_both_resources(self):
        project = license_check.load_project()
        for target in license_check.RESOURCE_TARGETS:
            with self.subTest(target=target):
                self.assertLessEqual(set(license_check.REQUIRED_RESOURCES),
                                     license_check.shipped_resources(project, target))

    def test_bundle_check_reports_missing_and_stale_files(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = pathlib.Path(directory) / "term-llm.app"
            bundle.mkdir()
            problems = license_check.bundle_problems(bundle)
            self.assertEqual(len(problems), 2)
            self.assertTrue(all("missing" in problem for problem in problems))
            (bundle / "LICENSE").write_text("not the license\n", encoding="utf-8")
            resources = bundle / "Contents/Resources"
            resources.mkdir(parents=True)
            (resources / "THIRD-PARTY-NOTICES.txt").write_bytes(license_check.NOTICES.read_bytes())
            problems = license_check.bundle_problems(bundle)
            self.assertEqual(len(problems), 1)
            self.assertIn("differs from LICENSE", problems[0])

    def test_changed_text_fails_the_digest_and_notice_checks(self):
        sources = license_check.load_sources()
        changed = {"components": [{**sources["components"][0], "sha256": "0" * 64}]}
        self.assertTrue(any("sha256" in problem for problem in license_check.check_licenses(changed)))
        self.assertNotEqual(license_check.render(sources), "".join(
            license_check.render(changed)))


if __name__ == "__main__":
    unittest.main()
