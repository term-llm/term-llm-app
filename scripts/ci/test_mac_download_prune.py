"""Server prune script vs the CI publisher's feed and archive naming; no server access."""
import base64
import contextlib
import importlib.machinery
import importlib.util
import io
import os
import sys
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import sparkle_updates as sparkle

SCRIPT = Path(__file__).resolve().parents[2] / "docs/deployment/term-llm-mac-prune"
SIGNATURE = base64.b64encode(bytes(64)).decode()
DAY = 86400


def load_prune():
    # SourceFileLoader would otherwise cache bytecode beside the deployment script.
    sys.dont_write_bytecode = True
    loader = importlib.machinery.SourceFileLoader("term_llm_mac_prune", str(SCRIPT))
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
    loader.exec_module(module)
    return module


prune = load_prune()


def metadata(number):
    data = {"build": str(number), "version": f"1.0.{number}", "title": f"term-llm {number}"}
    data["publicAsset"] = sparkle.public_asset(data, f"{number:064x}")
    return data


def publish_feed(numbers):
    """Appcast exactly as CI builds it, one release at a time."""
    previous = None
    for number in numbers:
        previous = sparkle.appcast(previous, metadata(number), SIGNATURE, 99)
    return previous


class PruneTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.dir = Path(temporary.name)

    def zips(self, numbers):
        for number in numbers:
            (self.dir / metadata(number)["publicAsset"]).write_bytes(b"zip")

    def run_prune(self, *args, days_later=5):
        later = prune.time.time() + days_later * DAY
        out, err = io.StringIO(), io.StringIO()
        argv = ["term-llm-mac-prune", "--dir", str(self.dir), *args]
        with mock.patch.object(prune.time, "time", return_value=later), mock.patch("sys.argv", argv), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                prune.main()
                code = 0
            except SystemExit as exit:
                code = exit.code
        return code, out.getvalue(), err.getvalue()

    def remaining(self):
        return sorted(p.name for p in self.dir.iterdir())

    def test_ci_archive_names_match_the_prune_pattern(self):
        for number in (1, 12, 9001):
            name = metadata(number)["publicAsset"]
            self.assertTrue(prune.NAME.fullmatch(name), name)
            self.assertTrue(sparkle.ARCHIVE_URL.fullmatch(prune.BASE + name), name)
        self.assertEqual(prune.BASE, sparkle.BASE)
        self.assertEqual(prune.NS, sparkle.NS)

    def test_fixed_latest_zip_is_never_a_prune_candidate(self):
        self.assertIsNone(prune.NAME.fullmatch("term-llm-macos-latest.zip"))
        self.zips([1, 2, 3])
        (self.dir / "appcast.xml").write_bytes(publish_feed([1, 2, 3]))
        latest = self.dir / "term-llm-macos-latest.zip"
        latest.write_bytes(b"latest archive")
        self.assertEqual(self.run_prune()[0], 0)
        self.assertEqual(latest.read_bytes(), b"latest archive")
        self.assertNotIn(metadata(1)["publicAsset"], self.remaining())

    def test_keeps_two_newest_feed_items_and_deletes_superseded(self):
        self.zips(range(1, 6))
        (self.dir / "appcast.xml").write_bytes(publish_feed(range(1, 6)))
        (self.dir / ".term-llm-macos-temp.zip.Ab12").write_bytes(b"partial")
        (self.dir / "unrelated.zip").write_bytes(b"other")
        code, out, _ = self.run_prune()
        self.assertEqual(code, 0)
        kept = {metadata(4)["publicAsset"], metadata(5)["publicAsset"]}
        self.assertEqual(self.remaining(), sorted(kept | {"appcast.xml", ".term-llm-macos-temp.zip.Ab12", "unrelated.zip"}))
        self.assertIn("freed 9 bytes", out)

    def test_grace_period_and_dry_run_delete_nothing(self):
        self.zips(range(1, 4))
        (self.dir / "appcast.xml").write_bytes(publish_feed(range(1, 4)))
        before = self.remaining()
        self.assertEqual(self.run_prune(days_later=1)[0], 0)
        self.assertEqual(self.remaining(), before)
        code, out, _ = self.run_prune("--dry-run")
        self.assertEqual(code, 0)
        self.assertIn("would delete " + metadata(1)["publicAsset"], out)
        self.assertEqual(self.remaining(), before)

    def test_fails_closed(self):
        self.zips(range(1, 4))
        cases = {
            "missing appcast": None,
            "malformed": b"<rss><channel><item>",
            "dtd": b'<!DOCTYPE rss [<!ENTITY x "y">]><rss><channel/></rss>',
            "no items": b"<rss><channel/></rss>",
            "foreign url": publish_feed([1, 2, 3]).replace(sparkle.BASE.encode(), b"https://example.com/mac/"),
            "newest missing on disk": publish_feed([1, 2, 3, 4]),
        }
        before = self.remaining()
        for label, feed in cases.items():
            with self.subTest(label):
                (self.dir / "appcast.xml").unlink(missing_ok=True)
                if feed is not None:
                    (self.dir / "appcast.xml").write_bytes(feed)
                code, _, err = self.run_prune()
                self.assertEqual(code, 1)
                self.assertIn("nothing deleted", err)
                self.assertEqual([n for n in self.remaining() if n != "appcast.xml"],
                                 [n for n in before if n != "appcast.xml"])

    def test_symlinks_are_never_followed_or_removed(self):
        self.zips([1, 2, 3])
        (self.dir / "appcast.xml").write_bytes(publish_feed([2, 3]))
        target = self.dir / metadata(1)["publicAsset"]
        target.rename(self.dir / "elsewhere")
        os.symlink(self.dir / "elsewhere", target)
        self.assertEqual(self.run_prune()[0], 0)
        self.assertTrue(target.is_symlink())


if __name__ == "__main__":
    unittest.main()
