"""Portable Sparkle publishing contract tests; never access a server or secrets."""
import base64
import io
import hashlib
import plistlib
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

import sparkle_updates as sparkle
from test_notarized_mac_build import (build, AppFixture, SHA, VALUES, TemporaryJob, REFERENCES)

SIGNATURE = base64.b64encode(bytes(64)).decode()


def metadata(build_number=30):
    return {"build": str(build_number), "version": f"1.0.{build_number}",
            "title": f"term-llm {build_number}", "asset": f"term-llm-macos-1.0.{build_number}.zip",
            "publicAsset": f"term-llm-macos-1.0.{build_number}-{build_number}-" + "0" * 64 + ".zip"}


def feed(previous=None, number=30):
    return sparkle.appcast(previous, metadata(number), SIGNATURE, 99)


class AppcastTests(unittest.TestCase):
    def test_fields_and_twenty_item_bound(self):
        previous = None
        for number in range(1, 31):
            previous = feed(previous, number)
        items = ET.fromstring(previous).findall("channel/item")
        self.assertEqual(len(items), 20)
        ns = "{" + sparkle.NS + "}"
        self.assertEqual([int(i.findtext(ns + "version")) for i in items], list(range(30, 10, -1)))
        item = items[0]
        self.assertEqual(item.findtext(ns + "shortVersionString"), "1.0.30")
        self.assertEqual(item.findtext(ns + "minimumSystemVersion"), "14.0")
        self.assertEqual(item.find("enclosure").get(ns + "edSignature"), SIGNATURE)
        self.assertIn("Requires macOS 14", item.findtext("description"))
        self.assertIsNone(item.find(ns + "releaseNotesLink"))
        self.assertTrue(item.find("enclosure").get("url").startswith(sparkle.BASE))

    def test_rejects_duplicate_and_downgrade_and_invalid_history(self):
        for old, number in ((feed(number=30), 30), (feed(number=30), 29),
                            (b"bad xml", 31), (b"<rss/>", 31),
                            (b'<!DOCTYPE rss><rss><channel/></rss>', 31),
                            (b"x" * (sparkle.MAX_FEED + 1), 31)):
            with self.subTest(number=number, old=old[:40]), self.assertRaises(ValueError):
                feed(old, number)

    def test_sort_history_and_reject_duplicate_in_history(self):
        root = ET.fromstring(feed(feed(number=1), 2))
        channel = root.find("channel")
        items = channel.findall("item")
        for item in items:
            channel.remove(item)
        channel.extend(reversed(items))
        result = ET.fromstring(feed(ET.tostring(root), 3))
        self.assertEqual([i.findtext("{" + sparkle.NS + "}version") for i in result.findall("channel/item")], ["3", "2", "1"])
        channel.append(items[0])
        with self.assertRaises(ValueError):
            feed(ET.tostring(root), 3)

    def test_rejects_invalid_historical_enclosures_and_minimum_os(self):
        ns = "{" + sparkle.NS + "}"
        mutations = [
            ("url", sparkle.BASE + "../term-llm-macos-1.0.zip"),
            ("url", sparkle.BASE + "term-llm-macos-1.0.zip?arbitrary=1"),
            ("url", sparkle.BASE + "term-llm-macos-x.zip"),
            ("url", "https://elsewhere.example/term-llm-macos-1.0.zip"),
            (ns + "edSignature", "not-base64"),
            (ns + "edSignature", base64.b64encode(bytes(63)).decode()),
            ("length", "0"), ("length", "-1"), ("length", "unknown"),
        ]
        for field, value in mutations:
            root = ET.fromstring(feed(number=1))
            root.find("channel/item/enclosure").set(field, value)
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                feed(ET.tostring(root), 2)
        for minimum in (None, "13.9", "malformed"):
            root = ET.fromstring(feed(number=1))
            root.find("channel/item/" + ns + "minimumSystemVersion").text = minimum
            with self.subTest(minimum=minimum), self.assertRaises(ValueError):
                feed(ET.tostring(root), 2)

    def test_rejects_history_over_parse_bound(self):
        root = ET.fromstring(feed(number=1))
        channel = root.find("channel")
        for _ in range(sparkle.MAX_HISTORY):
            channel.append(ET.Element("item"))
        with self.assertRaisesRegex(ValueError, "history limit"):
            feed(ET.tostring(root), 2)

    def test_version_only_public_url_is_rejected(self):
        data = metadata(31)
        data["publicAsset"] = data["asset"]
        with self.assertRaisesRegex(ValueError, "public archive URL"):
            sparkle.appcast(feed(), data, SIGNATURE, 1)


class FetchTests(unittest.TestCase):
    def test_requests_use_publisher_user_agent(self):
        # Cloudflare returns 403 for urllib's default Python-urllib agent.
        self.assertNotIn("Python-urllib", sparkle.USER_AGENT)
        opener = urllib.request._opener
        self.assertIn(("User-Agent", sparkle.USER_AGENT), opener.addheaders)
        self.assertFalse(any(name == "User-agent" for name, _ in opener.addheaders))

    def test_only_404_allows_initial_feed(self):
        for code in (404, 403, 429, 500):
            with self.subTest(code=code), mock.patch.object(sparkle.urllib.request, "urlopen", side_effect=urllib.error.HTTPError(sparkle.FEED, code, "error", {}, None)):
                if code == 404:
                    self.assertIsNone(sparkle.fetch(sparkle.FEED, 100, True))
                else:
                    with self.assertRaises(ValueError):
                        sparkle.fetch(sparkle.FEED, 100, True)

    def test_bounded_read_and_redirect_rejection(self):
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.geturl.return_value = sparkle.FEED
        response.read.return_value = b"x" * 101
        with mock.patch.object(sparkle.urllib.request, "urlopen", return_value=response):
            with self.assertRaises(ValueError):
                sparkle.fetch(sparkle.FEED, 100)
            response.read.assert_called_once_with(101)
            response.geturl.return_value = "http://unsafe/"
            with self.assertRaisesRegex(ValueError, "redirect"):
                sparkle.fetch(sparkle.FEED, 100)

    def test_tool_digest_checked_before_extract(self):
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.read.return_value = b"untrusted executable"
        with tempfile.TemporaryDirectory() as temp, mock.patch.object(sparkle.urllib.request, "urlopen", return_value=response):
            with self.assertRaisesRegex(ValueError, "SHA-256"):
                sparkle.fetch_tools(Path(temp))
            self.assertEqual(list(Path(temp).iterdir()), [])


class PublicArchiveVerificationTests(unittest.TestCase):
    def response(self, url, payload):
        response = io.BytesIO(payload)
        response.geturl = lambda: url
        return response

    def test_streams_get_with_exact_length_and_hash(self):
        payload = b"archive" * 20000
        digest = hashlib.sha256(payload).hexdigest()
        url = sparkle.BASE + sparkle.public_asset(metadata(), digest)
        response = self.response(url, payload)
        reads = []
        original_read = response.read
        def read(size):
            reads.append(size)
            return original_read(size)
        response.read = read
        with mock.patch.object(sparkle.urllib.request, "urlopen", return_value=response) as get:
            sparkle.verify_public_archive(url, digest, len(payload))
        get.assert_called_once_with(url, timeout=60)
        self.assertGreater(len(reads), 1)
        self.assertTrue(all(0 < size <= 65536 for size in reads))

    def test_missing_conflicting_short_oversized_and_redirects_fail(self):
        payload = b"expected ZIP"
        digest = hashlib.sha256(payload).hexdigest()
        url = sparkle.BASE + sparkle.public_asset(metadata(), digest)
        for content, final_url in ((b"conflicting!", url), (payload[:-1], url),
                                   (payload + b"X", url), (payload, "https://other.example/")):
            with self.subTest(content=content, final_url=final_url):
                with mock.patch.object(sparkle.urllib.request, "urlopen", return_value=self.response(final_url, content)):
                    with self.assertRaisesRegex(ValueError, "HTTPS verification failed"):
                        sparkle.verify_public_archive(url, digest, len(payload))
        with mock.patch.object(sparkle.urllib.request, "urlopen", side_effect=urllib.error.HTTPError(url, 404, "not found", {}, None)):
            with self.assertRaisesRegex(ValueError, "HTTPS verification failed"):
                sparkle.verify_public_archive(url, digest, len(payload))


class CredentialTests(TemporaryJob):
    def test_prepare_advances_past_website_release_missing_on_github(self):
        # GitHub still selects 1.0.1 after website 1.0.5 succeeded but GH failed.
        with mock.patch.object(sparkle, "fetch", return_value=feed(number=5)):
            self.prepare(build_number="7")
        self.assertEqual((self.work / "version.txt").read_text(), "1.0.6\n")
        self.assertIn("MARKETING_VERSION = 1.0.6\n", (self.work / build.SETTINGS_FILE).read_text())
        self.assertTrue(any("--verify" in call for call in self.tools.calls))

    def test_prepare_retains_github_version_when_ahead_of_feed(self):
        (self.work / "version.txt").write_text("1.0.9\n")
        with mock.patch.object(sparkle, "fetch", return_value=feed(number=5)):
            self.prepare()
        self.assertEqual((self.work / "version.txt").read_text(), "1.0.9\n")

    def test_marketing_recovery_ignores_other_major_minor_lines(self):
        data = metadata(5)
        data["version"] = "2.3.99"
        data["publicAsset"] = sparkle.public_asset(data, "0" * 64)
        previous = sparkle.appcast(None, data, SIGNATURE, 99)
        with mock.patch.object(sparkle, "fetch", return_value=previous):
            self.prepare()
        self.assertEqual((self.work / "version.txt").read_text(), "1.0.1\n")

    def test_prepare_never_adjusts_build_number_to_bypass_monotonicity(self):
        with mock.patch.object(sparkle, "fetch", return_value=feed(number=7)):
            with self.assertRaisesRegex(ValueError, "duplicate build or downgrade"):
                self.prepare(build_number="7")
        self.assertFalse((self.work / build.SETTINGS_FILE).exists())

    def test_prepare_verifies_history_before_advancing_marketing_version(self):
        original = self.tools._sign_update
        def signer(args):
            if "--verify" in args:
                return subprocess.CompletedProcess(args, 1, b"SECRET-OUTPUT", b"SECRET-ERROR")
            return original(args)
        self.tools._sign_update = signer
        stderr = io.StringIO()
        with mock.patch.object(sparkle, "fetch", return_value=feed(number=5)), mock.patch("sys.stderr", stderr):
            code = build.main(["--work-dir", str(self.work), "prepare", "--build-number", "7",
                               "--profiles-dir", str(self.profiles_dir),
                               "--profiles-destination", str(self.destination)], run=self.tools, environ=self.environ)
        self.assertEqual(code, 1)
        self.assertIn("::error::", stderr.getvalue())
        self.assertNotIn("SECRET-", stderr.getvalue())
        self.assertIn(sparkle.HELP, stderr.getvalue())
        self.assertEqual((self.work / "version.txt").read_text(), "1.0.1\n")
        self.assertFalse((self.work / build.SETTINGS_FILE).exists())

    def test_all_four_credentials_validated_before_archive(self):
        self.prepare()
        settings = (self.work / build.SETTINGS_FILE).read_text()
        self.assertIn("SPARKLE_PUBLIC_ED_KEY = " + VALUES["SPARKLE_PUBLIC_KEY"].decode(), settings)
        secret_dir = build.secrets_directory(self.work, self.tools)
        for name in sparkle.FILES:
            self.assertEqual((secret_dir / name).stat().st_mode & 0o777, 0o600)
        self.assertEqual(len(self.tools.commands("ssh-keygen", "-y")), 1)
        self.assertFalse(self.tools.commands("ditto"))

    def test_mismatched_key_pair_is_checked_cryptographically_before_archive(self):
        self.tools._swift = lambda args: subprocess.CompletedProcess(args, 1, b"", b"not a valid signature")
        with self.assertRaisesRegex(ValueError, sparkle.HELP):
            self.prepare()
        self.assertFalse((self.work / build.SETTINGS_FILE).exists())
        self.assertFalse(self.tools.commands("ditto"))
        invocation = self.tools.commands("swift")[0]
        self.assertNotIn(VALUES["SPARKLE_PRIVATE_KEY"].decode(), " ".join(invocation))

    def test_missing_credentials_emit_actions_error_with_setup_anchor(self):
        self.tools.op_values.pop(REFERENCES["SPARKLE_PUBLIC_KEY"])
        stderr = io.StringIO()
        with mock.patch("sys.stderr", stderr):
            code = build.main(["--work-dir", str(self.work), "prepare", "--build-number", "7",
                               "--profiles-dir", str(self.profiles_dir),
                               "--profiles-destination", str(self.destination)],
                              run=self.tools, environ=self.environ)
        self.assertEqual(code, 1)
        self.assertIn("::error::", stderr.getvalue())
        self.assertIn(sparkle.HELP, stderr.getvalue())
        for value in VALUES.values():
            self.assertNotIn(value.decode("utf-8", "replace"), stderr.getvalue())
        self.assertFalse((self.work / build.SETTINGS_FILE).exists())

    def test_legacy_96_byte_export_is_supported(self):
        self.tools.op_values[REFERENCES["SPARKLE_PRIVATE_KEY"]] = base64.b64encode(bytes(96))
        self.prepare()
        self.assertTrue(self.tools.commands("swift"))

    def test_secret_bearing_prepare_tool_errors_never_echo_stdout_or_stderr(self):
        sentinel = "SECRET-TOOL-OUTPUT-NEVER-PRINT"
        for branch in ("op", "sign_update", "swift", "ssh-private", "ssh-hosts"):
            with self.subTest(branch=branch):
                def run(args, **kwargs):
                    fail = (args[0] == branch or Path(args[0]).name == branch or
                            branch == "ssh-private" and args[:2] == ["ssh-keygen", "-y"] or
                            branch == "ssh-hosts" and args[:2] == ["ssh-keygen", "-l"])
                    if fail:
                        return subprocess.CompletedProcess(args, 1, sentinel.encode(), sentinel.encode())
                    return self.tools(args, **kwargs)
                stderr = io.StringIO()
                with mock.patch("sys.stderr", stderr):
                    code = build.main(["--work-dir", str(self.work), "prepare", "--build-number", "7",
                                       "--profiles-dir", str(self.profiles_dir),
                                       "--profiles-destination", str(self.destination)], run=run, environ=self.environ)
                self.assertEqual(code, 1)
                self.assertIn("::error::", stderr.getvalue())
                self.assertIn(sparkle.HELP, stderr.getvalue())
                self.assertNotIn(sentinel, stderr.getvalue())
                build.cleanup(self.work, self.tools, echo=lambda _: None)
                self.work.mkdir()
                (self.work / "version.txt").write_text("1.0.1\n")

    def test_missing_or_invalid_fields_fail_closed_and_do_not_leak(self):
        invalid = {
            "SPARKLE_PUBLIC_KEY": b"not base64",
            "SPARKLE_PRIVATE_KEY": base64.b64encode(b"z" * 64),
            "DOWNLOADS_SSH_PRIVATE_KEY": b"my secret malformed SSH key",
            "DOWNLOADS_SSH_KNOWN_HOSTS": b"attacker.example ssh-ed25519 AAAA",
        }
        directory = build.attach_ram_disk(self.work, self.tools)
        for name in invalid:
            for value in (b"", invalid[name]):
                with self.subTest(name=name, value=value):
                    self.tools.op_values[REFERENCES[name]] = value
                    with self.assertRaisesRegex(ValueError, sparkle.HELP):
                        sparkle.prepare(self.work, build.OnePassword(self.environ, self.tools),
                                        directory, lambda args: build._run(self.tools, args))
                    self.assertFalse((self.work / build.SETTINGS_FILE).exists())
                    self.tools.op_values[REFERENCES[name]] = VALUES[name]


class PublishingTests(AppFixture):
    def setUp(self):
        super().setUp()
        self.public_verify = mock.patch.object(sparkle, "verify_public_archive")
        self.public_verify.start()
        self.addCleanup(self.public_verify.stop)

    def fake_run(self, calls, fail=None):
        def run(args):
            calls.append(args)
            if args[0] == "ditto":
                Path(args[-1]).write_bytes(b"stapled exact zip bytes")
            if args[0] == "rsync" and (fail == "zip" or fail == "feed" and args[-2].endswith("appcast.xml")):
                raise ValueError("upload failed")
            return subprocess.CompletedProcess(args, 0, SIGNATURE.encode(), b"")
        return run

    def test_zip_then_feed_atomic_rsync_and_exact_github_archive(self):
        self.prepare()
        directory = build.secrets_directory(self.work, self.tools)
        calls = []
        with mock.patch.object(sparkle, "fetch", return_value=None):
            sparkle.publish(self.app, self.work, build.release_metadata(self.app), directory, self.fake_run(calls))
        uploads = [c for c in calls if c[0] == "rsync"]
        self.assertEqual(len(uploads), 2)
        self.assertTrue(uploads[0][-2].endswith(".zip"))
        self.assertTrue(any(c[-1].endswith("appcast.xml") and "sign_update" in c[0] for c in calls))
        self.assertTrue(uploads[1][-2].endswith("appcast.xml"))
        for call in uploads:
            if call[-2].endswith("appcast.xml"):
                self.assertEqual(call[-1], sparkle.DESTINATION)
                self.assertNotIn("--ignore-existing", call)
            else:
                self.assertTrue(call[-1].startswith(sparkle.DESTINATION + "term-llm-macos-1.0.1-7-"))
                self.assertIn("--ignore-existing", call)
            # openrsync rejects F644 and sends -r as --dirs, which rrsync refuses.
            self.assertIn("--chmod=Fu=rw,Fgo=r", call)
            self.assertNotIn("-r", call)
            self.assertNotIn("-rt", call)
            self.assertIn("--perms", call)
            self.assertNotIn("--inplace", call)
            self.assertNotIn("--delete", call)
            ssh = call[call.index("-e") + 1]
            self.assertIn("StrictHostKeyChecking=yes", ssh)
            self.assertIn("UserKnownHostsFile=", ssh)
            self.assertIn("BatchMode=yes", ssh)
            for option in ("ForwardAgent=no", "ClearAllForwardings=yes", "PasswordAuthentication=no",
                           "KbdInteractiveAuthentication=no", "IdentityAgent=none"):
                self.assertIn(option, ssh)
            self.assertNotIn("ssh-keyscan", ssh)
        build.publish(self.app, self.work, "owner/repo", SHA, self.tools, environ={})
        self.assertFalse(self.tools.commands("ditto"), "GitHub must never recompress")

    def test_failures_never_mark_published_or_allow_github(self):
        self.prepare()
        directory = build.secrets_directory(self.work, self.tools)
        for fail in ("zip", "feed"):
            calls = []
            (self.work / build.release_metadata(self.app)["asset"]).unlink(missing_ok=True)
            with self.subTest(fail=fail), mock.patch.object(sparkle, "fetch", return_value=None):
                with self.assertRaises(ValueError):
                    sparkle.publish(self.app, self.work, build.release_metadata(self.app), directory, self.fake_run(calls, fail))
                self.assertFalse((self.work / "sparkle-published.sha256").exists())
                with self.assertRaisesRegex(ValueError, "before GitHub"):
                    build.publish(self.app, self.work, "owner/repo", SHA, self.tools, environ={})
                self.assertFalse(self.tools.commands("gh"))
                if fail == "zip":
                    self.assertEqual(len([c for c in calls if c[0] == "rsync"]), 1)

    def test_changed_zip_blocks_github(self):
        self.prepare()
        calls = []
        with mock.patch.object(sparkle, "fetch", return_value=None):
            sparkle.publish(self.app, self.work, build.release_metadata(self.app),
                            build.secrets_directory(self.work, self.tools), self.fake_run(calls))
        (self.work / build.release_metadata(self.app)["asset"]).write_bytes(b"changed zip")
        with self.assertRaisesRegex(ValueError, "changed"):
            build.publish(self.app, self.work, "owner/repo", SHA, self.tools, environ={})
        self.assertFalse(self.tools.commands("gh"))

    def test_test_feed_or_wrong_app_key_cannot_ship(self):
        import plistlib
        self.prepare()
        path = self.app / "Contents/Info.plist"
        original = plistlib.loads(path.read_bytes())
        for name, value in (("SUFeedURL", "https://test.example/feed.xml"),
                            ("SUPublicEDKey", base64.b64encode(bytes(32)).decode())):
            path.write_bytes(plistlib.dumps({**original, name: value}))
            with self.assertRaisesRegex(ValueError, "production feed"):
                sparkle.verify_app(self.app, self.work)

    def test_mandatory_app_policy_is_type_checked_and_fail_closed(self):
        import plistlib
        self.prepare()
        path = self.app / "Contents/Info.plist"
        original = plistlib.loads(path.read_bytes())
        for name, invalid in (("SURequireSignedFeed", False), ("SUVerifyUpdateBeforeExtraction", False),
                              ("SUSignedFeedFailureExpirationInterval", 1), ("SUAllowsAutomaticUpdates", True),
                              ("SURequireSignedFeed", 1), ("SUSignedFeedFailureExpirationInterval", False)):
            for absent in (False, True):
                info = {**original, name: invalid}
                if absent:
                    del info[name]
                path.write_bytes(plistlib.dumps(info))
                with self.subTest(name=name, absent=absent), self.assertRaisesRegex(ValueError, name):
                    sparkle.verify_app(self.app, self.work)

    def test_existing_feed_verified_before_parse_or_packaging(self):
        self.prepare()
        previous = feed(number=2)
        calls = []
        runner = self.fake_run(calls)
        original_appcast = sparkle.appcast
        def checked_appcast(*args):
            self.assertTrue(any("--verify" in c for c in calls))
            return original_appcast(*args)
        def checked_run(args):
            if "--verify" in args:
                self.assertEqual(Path(args[-1]).read_bytes(), previous)
                self.assertEqual(args[1:4], ["--verify", "--ed-key-file", str(self.work / "secrets/sparkle-key")])
            return runner(args)
        with mock.patch.object(sparkle, "fetch", return_value=previous), mock.patch.object(sparkle, "appcast", side_effect=checked_appcast):
            sparkle.publish(self.app, self.work, build.release_metadata(self.app),
                            build.secrets_directory(self.work, self.tools), checked_run)
        self.assertEqual(calls[0][1], "--verify")
        self.assertFalse((self.work / "previous-appcast.xml").exists())

    def test_unavailable_or_oversized_feed_is_never_verified_parsed_or_uploaded(self):
        self.prepare()
        for previous in (b"x" * (sparkle.MAX_FEED + 1),):
            calls = []
            with mock.patch.object(sparkle, "fetch", return_value=previous), mock.patch.object(sparkle, "appcast") as parse:
                with self.assertRaisesRegex(ValueError, "size bound"):
                    sparkle.publish(self.app, self.work, build.release_metadata(self.app),
                                    build.secrets_directory(self.work, self.tools), self.fake_run(calls))
                parse.assert_not_called()
                self.assertEqual(calls, [])

    def test_secret_bearing_publish_tool_errors_are_fixed_and_redacted(self):
        sentinel = "PRIVATE-TOOL-OUTPUT-MUST-NOT-LEAK"
        for branch in ("verify", "zip-sign", "feed-sign", "zip-upload", "feed-upload"):
            with self.subTest(branch=branch):
                self.prepare()
                runner = self.fake_run([])
                failures = []
                def run(args, **kwargs):
                    fail = (branch == "verify" and "--verify" in args or
                            branch == "zip-sign" and "-p" in args or
                            branch == "feed-sign" and "sign_update" in args[0] and args[-1].endswith("appcast.xml") and "--verify" not in args or
                            branch == "zip-upload" and args[0] == "rsync" and args[-2].endswith(".zip") or
                            branch == "feed-upload" and args[0] == "rsync" and args[-2].endswith("appcast.xml"))
                    if fail:
                        failures.append(args)
                        return subprocess.CompletedProcess(args, 1, sentinel.encode(), sentinel.encode())
                    if args[0] in ("mount", "diskutil"):
                        return self.tools(args, **kwargs)
                    return runner(args)
                stderr = io.StringIO()
                with mock.patch.object(sparkle, "fetch", return_value=feed(number=2)), mock.patch("sys.stderr", stderr), mock.patch.object(sparkle, "appcast", wraps=sparkle.appcast) as parse:
                    code = build.main(["--work-dir", str(self.work), "publish-sparkle", "--app", str(self.app)],
                                      run=run, environ=self.environ)
                self.assertEqual(code, 1)
                self.assertIn("::error::", stderr.getvalue())
                self.assertIn(sparkle.HELP, stderr.getvalue())
                self.assertNotIn(sentinel, stderr.getvalue())
                self.assertEqual(len(failures), 1, "Must exercise the intended tool failure, not an earlier guard")
                self.assertFalse((self.work / "sparkle-published.sha256").exists())
                if branch == "verify":
                    parse.assert_not_called()
                # App fixture lives under work; preserve it while resetting release state.
                (self.work / build.release_metadata(self.app)["asset"]).unlink(missing_ok=True)
                for device in list(self.tools.mounts):
                    build.eject(self.tools, device)
                # Fake diskutil unmounts its state, not the test filesystem.
                shutil.rmtree(self.work / "secrets")

    def test_history_fetch_failure_performs_no_subprocesses(self):
        self.prepare()
        calls = []
        with mock.patch.object(sparkle, "fetch", side_effect=ValueError("HTTP 500")):
            with self.assertRaises(ValueError):
                sparkle.publish(self.app, self.work, metadata(), self.work, self.fake_run(calls))
        self.assertEqual(calls, [])


class PersistentPublishingTests(AppFixture):
    """Keep a fake public server across failed and subsequent CI jobs."""
    def setUp(self):
        super().setUp()
        self.prepare()
        self.remote = {}
        self.payload = b"first ZIP bytes"
        self.fail_feed = False
        self.calls = []
        self.fail_get = False

    def runner(self, args):
        self.calls.append(args)
        if args[0] == "ditto":
            Path(args[-1]).write_bytes(self.payload)
        if args[0] == "rsync":
            data = Path(args[-2]).read_bytes()
            if args[-2].endswith("appcast.xml"):
                if self.fail_feed:
                    raise ValueError("fake feed upload failed")
                self.remote[sparkle.FEED] = data
            else:
                self.assertIn("--ignore-existing", args)
                name = args[-1].removeprefix(sparkle.DESTINATION)
                self.remote.setdefault(sparkle.BASE + name, data)
        return subprocess.CompletedProcess(args, 0, SIGNATURE.encode(), b"")

    def get(self, url, timeout):
        self.assertEqual(timeout, 60)
        if self.fail_get or url not in self.remote:
            raise urllib.error.HTTPError(url, 404, "not found", {}, None)
        response = io.BytesIO(self.remote[url])
        response.geturl = lambda: url
        return response

    def publish(self):
        with mock.patch.object(sparkle, "fetch", side_effect=lambda *a, **kw: self.remote.get(sparkle.FEED)), mock.patch.object(sparkle.urllib.request, "urlopen", side_effect=self.get):
            sparkle.publish(self.app, self.work, build.release_metadata(self.app),
                            build.secrets_directory(self.work, self.tools), self.runner)

    def next_job(self, build_number, payload):
        # New runner workspace, represented by resetting only local release files;
        # the public server dictionary intentionally survives.
        (self.work / build.release_metadata(self.app)["asset"]).unlink(missing_ok=True)
        (self.work / "sparkle-published.sha256").unlink(missing_ok=True)
        info_path = self.app / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["CFBundleVersion"] = str(build_number)
        info_path.write_bytes(plistlib.dumps(info))
        self.payload = payload
        self.calls.clear()

    def test_failed_feed_retry_different_content_and_build_never_overwrites_orphan(self):
        self.fail_feed = True
        with self.assertRaisesRegex(ValueError, "upload failed"):
            self.publish()
        orphan_url, = self.remote
        self.assertNotIn(sparkle.FEED, self.remote)
        self.assertIn("-7-" + hashlib.sha256(self.payload).hexdigest(), orphan_url)
        original = self.remote[orphan_url]
        self.next_job(8, b"different ZIP for same marketing version")
        self.fail_feed = False
        self.publish()
        new_url = ET.fromstring(self.remote[sparkle.FEED]).find("channel/item/enclosure").get("url")
        self.assertNotEqual(new_url, orphan_url)
        self.assertEqual(self.remote[orphan_url], original)
        self.assertEqual(self.remote[new_url], self.payload)
        self.assertIn("-8-" + hashlib.sha256(self.payload).hexdigest(), new_url)
        self.assertEqual((self.work / "term-llm-macos-1.0.1.zip").read_bytes(), self.payload)

    def test_website_success_github_failure_next_job_advances_automatically(self):
        self.publish()
        original_feed = self.remote[sparkle.FEED]
        self.tools._gh = lambda args: subprocess.CompletedProcess(args, 1, b"", b"fake GitHub failure")
        with self.assertRaises(build.CommandError):
            build.publish(self.app, self.work, "owner/repo", SHA, self.tools, environ={})
        self.assertEqual(self.remote[sparkle.FEED], original_feed)
        self.next_job(8, b"next job ZIP")
        with mock.patch.object(sparkle, "fetch", return_value=original_feed):
            recovered = sparkle.advance_version(self.work, build.secrets_directory(self.work, self.tools),
                                                self.runner, "1.0.1", "8")
        self.assertEqual(recovered, "1.0.2")
        path = self.app / "Contents/Info.plist"
        info = plistlib.loads(path.read_bytes())
        info["CFBundleShortVersionString"] = recovered
        path.write_bytes(plistlib.dumps(info))
        self.publish()
        items = ET.fromstring(self.remote[sparkle.FEED]).findall("channel/item")
        self.assertEqual([i.findtext("{" + sparkle.NS + "}shortVersionString") for i in items], ["1.0.2", "1.0.1"])
        self.assertEqual(len([url for url in self.remote if url != sparkle.FEED]), 2)

    def test_existing_conflicting_content_is_not_overwritten_and_feed_not_uploaded(self):
        public = sparkle.BASE + sparkle.public_asset(build.release_metadata(self.app), hashlib.sha256(self.payload).hexdigest())
        self.remote[public] = b"conflicting existing content"
        with self.assertRaisesRegex(ValueError, "HTTPS verification failed"):
            self.publish()
        self.assertEqual(self.remote[public], b"conflicting existing content")
        self.assertNotIn(sparkle.FEED, self.remote)
        self.assertEqual(len([c for c in self.calls if c[0] == "rsync"]), 1)
        self.assertFalse((self.work / "sparkle-published.sha256").exists())

    def test_missing_https_archive_blocks_feed_even_when_rsync_succeeds(self):
        self.fail_get = True
        with self.assertRaisesRegex(ValueError, "HTTPS verification failed"):
            self.publish()
        self.assertNotIn(sparkle.FEED, self.remote)
        self.assertEqual(len([c for c in self.calls if c[0] == "rsync"]), 1)

    def test_identical_orphan_is_reused_without_overwrite(self):
        public = sparkle.BASE + sparkle.public_asset(build.release_metadata(self.app), hashlib.sha256(self.payload).hexdigest())
        self.remote[public] = self.payload
        self.publish()
        self.assertEqual(self.remote[public], self.payload)
        self.assertIn(sparkle.FEED, self.remote)

    def test_build_is_part_of_name_even_for_identical_archive_bytes(self):
        first = sparkle.public_asset(build.release_metadata(self.app), hashlib.sha256(self.payload).hexdigest())
        self.next_job(8, self.payload)
        second = sparkle.public_asset(build.release_metadata(self.app), hashlib.sha256(self.payload).hexdigest())
        self.assertNotEqual(first, second)


if __name__ == "__main__":
    unittest.main()
