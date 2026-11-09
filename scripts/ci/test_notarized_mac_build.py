#!/usr/bin/env python3
"""Portable tests for the notarized Mac build helper; every Apple tool is faked."""
import base64
import datetime
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).with_name("notarized-mac-build.py")
spec = importlib.util.spec_from_file_location("notarized_mac_build", SCRIPT)
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)

TEAM = build.TEAM_ID
NOW = datetime.datetime(2026, 11, 9, 0, 0, 0)
CERT = b"developer-id-certificate-der"
CERT_SHA1 = hashlib.sha1(CERT).hexdigest().upper()
OTHER_SHA1 = "A" * 40
IDENTITY = f"Developer ID Application: Sam Saffron ({TEAM})"
APP_UUID = "11111111-2222-3333-4444-555555555555"
EXT_UUID = "66666666-7777-8888-9999-AAAAAAAAAAAA"
LOGIN = "/Users/me/Library/Keychains/login.keychain-db"
P12_PASSWORD = "p12-password-value"
P12 = b"\x30\x82p12 bytes"  # DER starts with a SEQUENCE
NOTARY_KEY = b"-----BEGIN PRIVATE KEY-----\nkey\n-----END PRIVATE KEY-----\n"
TOKEN = "ops_service-account-token-value"
REFERENCES = {
    "MACOS_SIGN_P12": "op://term-llm CI/Developer ID Application/developer-id.p12",
    "MACOS_SIGN_PASSWORD": "op://term-llm CI/Developer ID Application/password",
    "MACOS_NOTARY_KEY": "op://term-llm CI/App Store Connect notary key/AuthKey_KEYID12345.p8",
    "MACOS_NOTARY_KEY_ID": "op://term-llm CI/App Store Connect notary key/key id",
    "MACOS_NOTARY_ISSUER_ID": "op://term-llm CI/App Store Connect notary key/issuer id",
}
VALUES = {
    "MACOS_SIGN_P12": P12,
    "MACOS_SIGN_PASSWORD": P12_PASSWORD.encode(),
    "MACOS_NOTARY_KEY": NOTARY_KEY,
    "MACOS_NOTARY_KEY_ID": b"KEYID12345",
    "MACOS_NOTARY_ISSUER_ID": b"issuer-uuid",
}
SHA = "0123456789abcdef0123456789abcdef01234567"


def profile(bundle_id, uuid, team=TEAM, platform="OSX", expires=datetime.datetime(2040, 1, 1),
            devices=None, certificates=(CERT,), aps="production"):
    entitlements = {"com.apple.application-identifier": f"{team}.{bundle_id}"}
    if aps:
        entitlements["com.apple.developer.aps-environment"] = aps
    document = {
        "Name": f"{bundle_id} Developer ID", "UUID": uuid, "TeamIdentifier": [team], "Platform": [platform],
        "ExpirationDate": expires, "DeveloperCertificates": list(certificates), "Entitlements": entitlements,
    }
    if devices:
        document["ProvisionedDevices"] = devices
    else:
        document["ProvisionsAllDevices"] = True
    return document


def completed(args, returncode=0, stdout=b"", stderr=b""):
    return subprocess.CompletedProcess(args, returncode, stdout, stderr)


class FakeTools:
    """Simulates security, diskutil, codesign, ditto, xcrun, spctl and gh with recorded calls."""

    def __init__(self, profiles=None, identities=None, search=None):
        self.calls = []
        self.inputs = {}
        self.envs = {}
        self.op_values = {REFERENCES[name]: value for name, value in VALUES.items()}
        self.devices = {}  # attached device -> diskutil info
        self.mounts = {}  # device -> (mount point, options)
        self.mount_options = "hfs, local, nodev, nosuid, nobrowse, mounted by me"
        self.mount_works = True
        self.profiles = profiles or {}
        self.identities = identities if identities is not None else [(CERT_SHA1, IDENTITY)]
        self.search = list(search or [LOGIN])
        self.keychains = set()
        self.import_password = P12_PASSWORD
        self.import_seen = None
        self.notary = {"id": "submission-1", "status": "Accepted"}
        self.notary_log = {"issues": []}
        self.spctl = (0, b"", b"app: accepted\nsource=Notarized Developer ID\n")
        self.codesign_details = {}
        self.codesign_entitlements = {}
        self.release_url = b"https://github.com/owner/repo/releases/tag/mac-v1.0.1\n"

    def __call__(self, args, capture_output=True, check=False, input=None, env=None):
        self.calls.append(list(args))
        if input is not None:
            self.inputs[len(self.calls) - 1] = input
        self.envs[len(self.calls) - 1] = env
        handler = getattr(self, "_" + args[0].replace("-", "_"))
        return handler(args)

    def input_for(self, *prefix):
        return [self.inputs.get(index) for index, call in enumerate(self.calls) if tuple(call[:len(prefix)]) == prefix]

    def stale_mount(self, device, mount_point):
        self.devices[device] = {"BusProtocol": "Disk Image", "TotalSize": build.RAM_DISK_SECTORS * 512}
        self.mounts[device] = (str(mount_point), self.mount_options)

    def _diskutil(self, args):
        if args[1:4] == ["image", "attach", "--noMount"]:
            device = f"/dev/disk{40 + len(self.devices)}"
            self.devices[device] = {"BusProtocol": "Disk Image", "TotalSize": build.RAM_DISK_SECTORS * 512}
            return completed(args, stdout=f"{device}\n".encode())
        if args[1] == "mount":
            if self.mount_works:
                self.mounts[args[-1]] = (args[args.index("-mountPoint") + 1], self.mount_options)
            return completed(args)
        if args[1] == "eject":
            self.mounts.pop(args[-1], None)
            return completed(args) if self.devices.pop(args[-1], None) is not None else completed(args, 1)
        if args[1] == "unmountDisk":
            self.mounts.pop(args[-1], None)
            return completed(args)
        if args[1:3] == ["info", "-plist"]:
            info = self.devices.get(args[-1])
            if info is None:
                return completed(args, 1)
            mount_point = self.mounts.get(args[-1], ("",))[0]
            return completed(args, stdout=plistlib.dumps({**info, "MountPoint": mount_point}))
        raise AssertionError(f"unexpected diskutil call {args}")

    def _newfs_hfs(self, args):
        return completed(args)

    def _op(self, args):
        assert args[:4] == ["op", "read", "--no-newline", "--cache=false"], args
        assert args[4] == "--config"
        env = self.envs[len(self.calls) - 1] or {}
        if env.get(build.OP_TOKEN) != TOKEN:
            return completed(args, 1, stderr=b"[ERROR] authentication required")
        if args[-1] not in self.op_values:
            return completed(args, 1, stderr=f'[ERROR] could not read secret "{args[-1]}"'.encode())
        return completed(args, stdout=self.op_values[args[-1]])

    def _mount(self, args):
        lines = ["/dev/disk1s1 on / (apfs, sealed, local, read-only, journaled)"]
        lines += [f"{device} on {os.path.realpath(point)} ({options})" for device, (point, options) in self.mounts.items()]
        return completed(args, stdout=("\n".join(lines) + "\n").encode())

    def commands(self, *prefix):
        return [call for call in self.calls if tuple(call[:len(prefix)]) == prefix]

    def _security(self, args):
        command = args[1]
        if command == "list-keychains":
            if "-s" in args:
                self.search = args[args.index("-s") + 1:]
                return completed(args)
            return completed(args, stdout="".join(f'    "{path}"\n' for path in self.search).encode())
        if command == "cms":
            return completed(args, stdout=plistlib.dumps(self.profiles[args[-1]]))
        if command == "create-keychain":
            Path(args[-1]).write_bytes(b"keychain")
            self.keychains.add(args[-1])
            return completed(args)
        if command in {"set-keychain-settings", "unlock-keychain", "set-key-partition-list"}:
            return completed(args)
        if command == "import":
            assert args[2] == "/dev/stdin", "the .p12 must be piped, never read from a file"
            self.import_seen = self.inputs.get(len(self.calls) - 1)
            password = args[args.index("-P") + 1]
            if password != self.import_password:
                return completed(args, 1, stderr=b"security: SecKeychainItemImport: MAC verification failed")
            return completed(args)
        if command == "find-identity":
            lines = [f'  {index}) {sha1} "{name}"' for index, (sha1, name) in enumerate(self.identities, 1)]
            lines.append(f"     {len(self.identities)} valid identities found")
            return completed(args, stdout=("\n".join(lines) + "\n").encode())
        if command == "delete-keychain":
            Path(args[-1]).unlink()
            self.search = [path for path in self.search if path != args[-1]]
            return completed(args)
        raise AssertionError(f"unexpected security call {args}")

    def _codesign(self, args):
        if "--verify" in args:
            return completed(args)
        path = args[-1]
        if "--entitlements" in args:
            return completed(args, stdout=plistlib.dumps(self.codesign_entitlements[Path(path).name]))
        return completed(args, stderr=self.codesign_details[Path(path).name].encode())

    def _ditto(self, args):
        Path(args[-1]).write_bytes(b"zip of " + args[-2].encode())
        return completed(args)

    def _xcrun(self, args):
        if args[1:3] == ["notarytool", "submit"]:
            return completed(args, stdout=json.dumps(self.notary).encode())
        if args[1:3] == ["notarytool", "log"]:
            Path(args[-1]).write_text(json.dumps(self.notary_log))
            return completed(args)
        if args[1] == "stapler":
            return completed(args)
        raise AssertionError(f"unexpected xcrun call {args}")

    def _spctl(self, args):
        code, out, err = self.spctl
        return completed(args, code, out, err)

    def _gh(self, args):
        return completed(args, stdout=self.release_url)


class TemporaryJob(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.runner_temp = self.root / "_temp"
        self.runner_temp.mkdir()
        self.work = self.runner_temp / "term-llm-mac-release.abc123"
        self.work.mkdir()
        self.profiles_dir = self.root / "profiles"
        self.profiles_dir.mkdir()
        self.destination = self.root / "Provisioning Profiles"
        self.app_profile = self.profiles_dir / "term-llm.provisionprofile"
        self.ext_profile = self.profiles_dir / "TermLLMNotificationService.provisionprofile"
        self.app_profile.write_bytes(b"app profile")
        self.ext_profile.write_bytes(b"extension profile")
        self.tools = FakeTools(profiles={
            str(self.app_profile): profile("com.termllm.app", APP_UUID),
            str(self.ext_profile): profile("com.termllm.app.NotificationService", EXT_UUID, aps=None),
        })
        self.environ = {
            build.OP_TOKEN: TOKEN,
            **{f"{name}_REF": reference for name, reference in REFERENCES.items()},
            "RUNNER_TEMP": str(self.runner_temp),
        }

    def tearDown(self):
        self.temporary.cleanup()

    def prepare(self, build_number="7"):
        return build.prepare(self.work, build.OnePassword(self.environ, self.tools), build_number,
                             self.profiles_dir, self.destination, self.tools, now=NOW)


class ProfileValidationTests(unittest.TestCase):
    def test_developer_id_profile_summary(self):
        summary = build.profile_summary(profile("com.termllm.app", APP_UUID), "com.termllm.app", NOW)
        self.assertEqual(summary["uuid"], APP_UUID)
        self.assertEqual(summary["certificates"], [CERT_SHA1])

    def test_rejects_profiles_that_cannot_sign_this_distribution(self):
        managed = profile("com.termllm.app", APP_UUID)
        managed["IsXcodeManaged"] = True
        cases = {
            "development": profile("com.termllm.app", APP_UUID, devices=["00008103-0001"]),
            "xcode managed": managed,
            "team": profile("com.termllm.app", APP_UUID, team="ZZZZZZZZZZ"),
            "platform": profile("com.termllm.app", APP_UUID, platform="iOS"),
            "expired": profile("com.termllm.app", APP_UUID, expires=datetime.datetime(2026, 1, 1)),
            "bundle": profile("com.termllm.app.NotificationService", APP_UUID),
            "uuid": profile("com.termllm.app", "not-a-uuid"),
        }
        for label, document in cases.items():
            with self.subTest(label), self.assertRaises(ValueError):
                build.profile_summary(document, "com.termllm.app", NOW)


class SearchListTests(unittest.TestCase):
    def test_parses_quoted_paths_with_spaces(self):
        output = '    "/Users/me/Library/Keychains/login.keychain-db"\n    "/Users/me/My Keys/x.keychain-db"\n'
        self.assertEqual(build.parse_search_list(output),
                         [LOGIN, "/Users/me/My Keys/x.keychain-db"])

    def test_filters_only_job_keychains(self):
        paths = [
            "/r/_temp/term-llm-mac-release.abc/secrets/signing.keychain-db",
            LOGIN,
            "/r/_temp/term-llm-mac-release.abc/secrets/other.keychain-db",
            "/r/_temp/term-llm-mac-release.abc/signing.keychain-db",
            "/r/_temp/not-term-llm-mac-release.abc/secrets/signing.keychain-db.bak",
        ]
        self.assertEqual(build.without_job_keychains(paths), paths[1:])

    def test_never_sets_an_empty_search_list(self):
        tools = FakeTools()
        with self.assertRaises(ValueError):
            build.set_search_list(tools, [])
        self.assertEqual(tools.calls, [])


class IdentityTests(unittest.TestCase):
    def output(self, identities):
        tools = FakeTools(identities=identities)
        return tools(["security", "find-identity", "-v", "-p", "codesigning", "x"]).stdout.decode()

    def test_selects_the_single_team_developer_id_identity(self):
        output = self.output([
            ("B" * 40, "Apple Development: Sam Saffron (TS73Z56E76)"),
            ("C" * 40, "Developer ID Application: Someone Else (ZZZZZZZZZZ)"),
            (CERT_SHA1, IDENTITY),
        ])
        self.assertEqual(build.select_identity(output), (CERT_SHA1, IDENTITY))

    def test_requires_exactly_one_identity(self):
        for identities in ([], [(CERT_SHA1, IDENTITY), (OTHER_SHA1, IDENTITY.replace("Sam", "Other"))]):
            with self.subTest(count=len(identities)), self.assertRaises(ValueError):
                build.select_identity(self.output(identities))


class WorkDirectoryTests(unittest.TestCase):
    def test_accepts_only_job_directories_inside_runner_temp(self):
        with tempfile.TemporaryDirectory() as temporary:
            runner_temp = Path(temporary).resolve()
            good = runner_temp / "term-llm-mac-release.x1"
            self.assertEqual(build.work_directory(good, str(runner_temp)), good)
            for bad in (runner_temp / "elsewhere", runner_temp / "a" / "term-llm-mac-release.x1",
                        runner_temp.parent / "term-llm-mac-release.x1"):
                with self.subTest(bad=bad), self.assertRaises(ValueError):
                    build.work_directory(bad, str(runner_temp))
            with self.assertRaises(ValueError):
                build.work_directory(good, None)


def files_containing(root, needle):
    """Every regular file under root whose bytes contain needle."""
    return [path for path in Path(root).rglob("*") if path.is_file() and needle in path.read_bytes()]


class PrepareTests(TemporaryJob):
    def keychain(self):
        return str(self.work / build.SECRETS_DIR / build.KEYCHAIN_FILE)

    def test_installs_profiles_imports_identity_and_writes_settings(self):
        self.assertEqual(self.prepare(), IDENTITY)
        self.assertEqual(self.tools.search, [self.keychain(), LOGIN])
        state = build.load_state(self.work)
        self.assertEqual(state["keychain"], self.keychain())
        self.assertEqual(state["searchList"], [LOGIN])
        self.assertEqual(state["secrets"], str(self.work / build.SECRETS_DIR))
        self.assertEqual(sorted(state["installedProfiles"]), sorted(
            str(self.destination / f"{uuid}.provisionprofile") for uuid in (APP_UUID, EXT_UUID)))
        self.assertEqual((self.destination / f"{APP_UUID}.provisionprofile").read_bytes(), b"app profile")

        settings = (self.work / build.SETTINGS_FILE).read_text()
        self.assertIn("CODE_SIGN_STYLE = Manual\n", settings)
        self.assertIn(f"CODE_SIGN_IDENTITY = {IDENTITY}\n", settings)
        self.assertIn("PROVISIONING_PROFILE_SPECIFIER = $(TERMLLM_DEVELOPER_ID_PROFILE_$(TARGET_NAME))\n", settings)
        self.assertIn(f"TERMLLM_DEVELOPER_ID_PROFILE_TermLLMMac = {APP_UUID}\n", settings)
        self.assertIn(f"TERMLLM_DEVELOPER_ID_PROFILE_TermLLMMacNotificationService = {EXT_UUID}\n", settings)
        self.assertIn("CURRENT_PROJECT_VERSION = 7\n", settings)

        options = plistlib.loads((self.work / build.EXPORT_OPTIONS_FILE).read_bytes())
        self.assertEqual(options["method"], "developer-id")
        self.assertEqual(options["signingStyle"], "manual")
        self.assertEqual(options["signingCertificate"], CERT_SHA1)
        self.assertEqual(options["provisioningProfiles"], {
            "com.termllm.app": APP_UUID, "com.termllm.app.NotificationService": EXT_UUID})

    def test_signing_material_only_lives_on_a_private_ram_disk(self):
        self.prepare()
        device = build.load_state(self.work)["ramDisk"]
        self.assertEqual(self.tools.commands("diskutil", "image", "attach"),
                         [["diskutil", "image", "attach", "--noMount", f"ram://{build.RAM_DISK_SECTORS}"]])
        self.assertEqual(self.tools.commands("diskutil", "mount"), [[
            "diskutil", "mount", "nobrowse", "-mountOptions", "owners", "-mountPoint",
            str(self.work / build.SECRETS_DIR), device]])
        imported = self.tools.commands("security", "import")[0]
        self.assertEqual(imported[2], "/dev/stdin")
        self.assertIn("-x", imported, "the private key must be non-extractable")
        self.assertEqual(self.tools.input_for("security", "import"), [P12])
        self.assertEqual(files_containing(self.root, P12), [])
        self.assertTrue(self.tools.commands("security", "create-keychain")[0][-1].startswith(
            str(self.work / build.SECRETS_DIR) + "/"))

    def test_refuses_secrets_unless_the_ram_disk_is_mounted_private(self):
        for label, change in (("noowners", lambda: setattr(self.tools, "mount_options", "hfs, noowners, nobrowse")),
                              ("browsable", lambda: setattr(self.tools, "mount_options", "hfs, local, nodev")),
                              ("not mounted", lambda: setattr(self.tools, "mount_works", False))):
            with self.subTest(label):
                self.tearDown()
                self.setUp()
                change()
                with self.assertRaises(ValueError):
                    self.prepare()
                self.assertEqual(self.tools.commands("security", "create-keychain"), [])
                self.assertEqual(self.tools.commands("security", "import"), [])

    def test_leaves_profiles_xcode_already_has(self):
        self.destination.mkdir()
        existing = self.destination / f"{APP_UUID}.provisionprofile"
        existing.write_bytes(b"already installed")
        self.prepare()
        self.assertEqual(build.load_state(self.work)["installedProfiles"],
                         [str(self.destination / f"{EXT_UUID}.provisionprofile")])
        self.assertEqual(existing.read_bytes(), b"already installed")

    def test_missing_or_non_push_profiles_fail_before_any_secret_is_used(self):
        self.tools.profiles[str(self.app_profile)] = profile("com.termllm.app", APP_UUID, aps=None)
        with self.assertRaisesRegex(ValueError, "Push Notifications"):
            self.prepare()
        self.tools.profiles[str(self.app_profile)] = profile("com.termllm.app", APP_UUID)
        self.ext_profile.unlink()
        with self.assertRaisesRegex(ValueError, "Missing Developer ID provisioning profile"):
            self.prepare()
        self.assertEqual(self.tools.commands("diskutil", "image", "attach"), [])
        self.assertEqual(self.tools.commands("security", "create-keychain"), [])
        self.assertFalse(self.destination.exists() and any(self.destination.iterdir()))

    def test_profile_for_another_certificate_is_rejected_after_recording_the_keychain(self):
        self.tools.identities = [(OTHER_SHA1, IDENTITY)]
        with self.assertRaisesRegex(ValueError, "not generated for the Developer ID certificate"):
            self.prepare()
        self.assertEqual(build.load_state(self.work)["keychain"], self.keychain())
        self.assertFalse((self.work / build.SETTINGS_FILE).exists())

    def test_import_failure_never_reports_secrets(self):
        self.tools.import_password = "something else"
        with self.assertRaises(build.CommandError) as raised:
            self.prepare()
        self.assertNotIn(P12_PASSWORD, str(raised.exception))
        self.assertIn("security import", str(raised.exception))
        self.assertEqual(build.load_state(self.work)["keychain"], self.keychain())
        self.assertEqual(self.tools.search, [LOGIN])
        self.assertEqual(files_containing(self.root, P12), [])

    def test_unusable_1password_values_fail_before_creating_a_keychain(self):
        cases = {
            "no token": lambda: self.environ.pop(build.OP_TOKEN),
            "not a reference": lambda: self.environ.update(MACOS_SIGN_P12_REF="/Users/me/developer-id.p12"),
            "missing item": lambda: self.tools.op_values.pop(REFERENCES["MACOS_SIGN_P12"]),
            "not a .p12": lambda: self.tools.op_values.update({REFERENCES["MACOS_SIGN_P12"]: b"hello"}),
            "multi-line password": lambda: self.tools.op_values.update({REFERENCES["MACOS_SIGN_PASSWORD"]: b"a\nb"}),
        }
        for label, change in cases.items():
            with self.subTest(label):
                self.tearDown()
                self.setUp()
                change()
                with self.assertRaises((ValueError, build.CommandError)) as raised:
                    self.prepare()
                self.assertNotIn(TOKEN, str(raised.exception))
                self.assertEqual(self.tools.commands("security", "create-keychain"), [])

    def test_only_op_receives_the_token_and_keeps_its_state_on_the_ram_disk(self):
        self.environ.update(OP_CONNECT_HOST="https://connect.example", OP_ACCOUNT="my.1password.com")
        self.prepare()
        secrets_dir = str(self.work / build.SECRETS_DIR)
        reads = [index for index, call in enumerate(self.tools.calls) if call[0] == "op"]
        self.assertEqual([self.tools.calls[index][-1] for index in reads],
                         [REFERENCES["MACOS_SIGN_P12"], REFERENCES["MACOS_SIGN_PASSWORD"]])
        for index in reads:
            call = self.tools.calls[index]
            self.assertEqual(call[call.index("--config") + 1], secrets_dir + "/" + build.OP_CONFIG_DIR)
            self.assertEqual(self.tools.envs[index][build.OP_TOKEN], TOKEN)
            self.assertEqual(sorted(key for key in self.tools.envs[index] if key.startswith("OP_")), [build.OP_TOKEN])
        for index, call in enumerate(self.tools.calls):
            if call[0] != "op":
                self.assertIsNone(self.tools.envs[index], call[:2])
        self.assertTrue(all(TOKEN not in " ".join(call) for call in self.tools.calls))

    def test_accepts_base64_stored_values(self):
        self.tools.op_values[REFERENCES["MACOS_SIGN_P12"]] = base64.b64encode(P12)
        self.prepare()
        self.assertEqual(self.tools.input_for("security", "import"), [P12])

    def test_rejects_non_numeric_build_numbers(self):
        for value in ("0", "-1", "1.2", "7; rm -rf /", ""):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.prepare(value)
        self.assertEqual(self.tools.calls, [])

    def test_removes_leftovers_of_killed_jobs(self):
        stale_secrets = self.runner_temp / "term-llm-mac-release.old" / build.SECRETS_DIR
        self.tools.search = [str(stale_secrets / build.KEYCHAIN_FILE), LOGIN]
        self.tools.stale_mount("/dev/disk30", stale_secrets)
        self.prepare()
        self.assertEqual(self.tools.search, [self.keychain(), LOGIN])
        self.assertNotIn("/dev/disk30", self.tools.mounts)
        self.assertIn(["diskutil", "eject", "/dev/disk30"], self.tools.calls)


class CleanupTests(TemporaryJob):
    def cleanup(self, messages=None):
        return build.cleanup(self.work, self.tools, echo=(messages.append if messages is not None else lambda _: None))

    def test_removes_everything_prepare_added(self):
        unrelated = self.destination / "unrelated.provisionprofile"
        self.prepare()
        device = build.load_state(self.work)["ramDisk"]
        unrelated.write_bytes(b"keep")
        keychain = str(self.work / build.SECRETS_DIR / build.KEYCHAIN_FILE)
        self.assertTrue(self.cleanup())
        self.assertEqual(self.tools.search, [LOGIN])
        self.assertEqual(self.tools.commands("security", "delete-keychain"),
                         [["security", "delete-keychain", keychain]])
        self.assertIn(["diskutil", "eject", device], self.tools.calls)
        self.assertEqual(self.tools.mounts, {})
        self.assertEqual(sorted(path.name for path in self.destination.iterdir()), ["unrelated.provisionprofile"])
        self.assertFalse(self.work.exists())

    def test_ejects_a_ram_disk_that_never_mounted(self):
        self.tools.mount_works = False
        with self.assertRaises(ValueError):
            self.prepare()
        device = build.load_state(self.work)["ramDisk"]
        self.assertTrue(self.cleanup())
        self.assertIn(["diskutil", "eject", device], self.tools.calls)
        self.assertNotIn(device, self.tools.devices)

    def test_never_ejects_a_reused_device_number(self):
        self.tools.mount_works = False
        with self.assertRaises(ValueError):
            self.prepare()
        device = build.load_state(self.work)["ramDisk"]
        self.tools.devices[device] = {"BusProtocol": "USB", "TotalSize": 64 * 2 ** 30}  # someone else's disk now
        self.assertTrue(self.cleanup())
        self.assertNotIn(["diskutil", "eject", device], self.tools.calls)

    def test_cleanup_without_prepare_removes_only_job_leftovers(self):
        stale_secrets = self.runner_temp / "term-llm-mac-release.old" / build.SECRETS_DIR
        self.tools.search = [LOGIN, str(stale_secrets / build.KEYCHAIN_FILE)]
        self.tools.stale_mount("/dev/disk30", stale_secrets)
        self.tools.stale_mount("/dev/disk31", self.root / "Volumes" / "Photos")
        self.assertTrue(self.cleanup())
        self.assertEqual(self.tools.search, [LOGIN])
        self.assertEqual(self.tools.commands("security", "delete-keychain"), [])
        self.assertEqual(list(self.tools.mounts), ["/dev/disk31"])

    def test_cleanup_restores_saved_list_rather_than_clearing_it(self):
        self.prepare()
        self.tools.search = [str(self.work / build.SECRETS_DIR / build.KEYCHAIN_FILE)]
        self.assertTrue(self.cleanup())
        self.assertEqual(self.tools.search, [LOGIN])

    def test_cleanup_refuses_to_empty_the_search_list(self):
        only = str(self.work / build.SECRETS_DIR / build.KEYCHAIN_FILE)
        self.tools.search = [only]
        messages = []
        self.assertFalse(self.cleanup(messages))
        self.assertEqual(self.tools.search, [only])
        self.assertTrue(any("would be empty" in message for message in messages))


class AppFixture(TemporaryJob):
    def setUp(self):
        super().setUp()
        self.app = self.work / "export" / build.APP_NAME
        self.extension = self.app / build.EXTENSION_PATH
        (self.extension / "Contents").mkdir(parents=True)
        with open(self.app / "Contents/Info.plist", "wb") as handle:
            plistlib.dump({"CFBundleShortVersionString": "1.0.1", "CFBundleVersion": "7",
                           "LSMinimumSystemVersion": "14.0"}, handle)
        self.reset_signatures()

    def reset_signatures(self):
        for bundle in (self.app, self.extension):
            (bundle / "Contents/embedded.provisionprofile").write_bytes(b"profile")
        details = (f"Executable=x\nCodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+7\n"
                   f"Authority=Developer ID Application: Sam Saffron ({TEAM})\n"
                   f"Authority=Developer ID Certification Authority\nTimestamp=9 Nov 2026 at 11:00:00\n"
                   f"TeamIdentifier={TEAM}\n")
        self.tools.codesign_details = {self.app.name: details, self.extension.name: details}
        shared = {"keychain-access-groups": [build.KEYCHAIN_GROUP],
                  "com.apple.security.application-groups": [build.SHARED_GROUP]}
        self.tools.codesign_entitlements = {
            self.app.name: {**shared, "com.apple.developer.aps-environment": "production"},
            self.extension.name: {**shared, "com.apple.security.app-sandbox": True},
        }


class VerifyTests(AppFixture):
    def test_accepts_distribution_signed_bundles(self):
        build.verify_signature(self.app, self.tools)

    def test_rejects_bundles_that_would_not_work_as_distributed(self):
        app, extension = self.app.name, self.extension.name

        def entitlements(bundle, **changes):
            return lambda: self.tools.codesign_entitlements[bundle].update(changes)

        def details(old, new):
            return lambda: self.tools.codesign_details.update(
                {app: self.tools.codesign_details[app].replace(old, new)})

        mutations = {
            "development push": entitlements(app, **{"com.apple.developer.aps-environment": "development"}),
            "debuggable": entitlements(app, **{"com.apple.security.get-task-allow": True}),
            "unsandboxed extension": entitlements(extension, **{"com.apple.security.app-sandbox": False}),
            "lost keychain group": entitlements(extension, **{"keychain-access-groups": []}),
            "no timestamp": details("Timestamp=", "Signed Time="),
            "development identity": details("Developer ID Application", "Apple Development"),
            "no runtime": details("(runtime)", "(none)"),
            "no profile": lambda: (self.extension / "Contents/embedded.provisionprofile").unlink(),
        }
        for label, mutate in mutations.items():
            with self.subTest(label):
                self.reset_signatures()
                mutate()
                with self.assertRaises(ValueError):
                    build.verify_signature(self.app, self.tools)


class NotarizeTests(AppFixture):
    def setUp(self):
        super().setUp()
        self.prepare()
        self.secrets = self.work / build.SECRETS_DIR
        self.messages = []

    def stage(self):
        build.stage_notary_key(self.work, build.OnePassword(self.environ, self.tools), self.tools)

    def notarize(self, stage=True):
        if stage:
            self.stage()
        return build.notarize(self.app, self.work, self.tools, echo=self.messages.append)

    def test_key_is_only_staged_on_the_ram_disk(self):
        self.stage()
        self.assertEqual(files_containing(self.root, NOTARY_KEY), [self.secrets / build.NOTARY_KEY_FILE])
        self.assertEqual((self.secrets / build.NOTARY_KEY_FILE).stat().st_mode & 0o777, 0o600)
        self.tools.op_values[REFERENCES["MACOS_NOTARY_KEY"]] = base64.b64encode(NOTARY_KEY)
        self.stage()
        self.assertEqual((self.secrets / build.NOTARY_KEY_FILE).read_bytes(), NOTARY_KEY)

    def test_accepted_submission_is_stapled_assessed_and_the_key_removed(self):
        self.assertEqual(self.notarize(), "submission-1")
        submit = self.tools.commands("xcrun", "notarytool", "submit")[0]
        self.assertIn("--wait", submit)
        self.assertEqual(submit[submit.index("--key") + 1], str(self.secrets / build.NOTARY_KEY_FILE))
        self.assertEqual(submit[submit.index("--key-id") + 1], "KEYID12345")
        self.assertEqual(self.tools.commands("xcrun", "stapler", "staple"),
                         [["xcrun", "stapler", "staple", str(self.app)]])
        self.assertTrue(self.tools.commands("xcrun", "stapler", "validate"))
        self.assertEqual(files_containing(self.root, NOTARY_KEY), [])
        self.assertFalse((self.secrets / build.NOTARY_IDS_FILE).exists())
        self.assertFalse((self.work / "notarization-upload.zip").exists())
        self.assertNotIn(NOTARY_KEY.decode(), "\n".join(self.messages))

    def test_rejected_submission_reports_issues_and_removes_the_key(self):
        self.tools.notary = {"id": "submission-2", "status": "Invalid"}
        self.tools.notary_log = {"issues": [{"severity": "error", "path": "term-llm.app/Contents/MacOS/x",
                                             "message": "The signature does not include a secure timestamp."}]}
        with self.assertRaisesRegex(ValueError, "submission-2 finished as Invalid"):
            self.notarize()
        self.assertTrue(any("secure timestamp" in message for message in self.messages))
        self.assertEqual(files_containing(self.root, NOTARY_KEY), [])
        self.assertEqual(self.tools.commands("xcrun", "stapler"), [])

    def test_gatekeeper_must_accept_the_stapled_app(self):
        self.tools.spctl = (3, b"", b"app: rejected\nsource=Unnotarized Developer ID\n")
        with self.assertRaisesRegex(ValueError, "Gatekeeper"):
            self.notarize()

    def test_disabled_gatekeeper_is_reported_not_trusted(self):
        self.tools.spctl = (0, b"", b"app: accepted\nsource=assessments disabled\n")
        self.notarize()
        self.assertTrue(any("assessments are disabled" in message for message in self.messages))

    def test_missing_notary_secret_or_unstaged_key_fails_before_upload(self):
        self.environ["MACOS_NOTARY_ISSUER_ID_REF"] = ""
        with self.assertRaisesRegex(ValueError, "MACOS_NOTARY_ISSUER_ID_REF"):
            self.stage()
        with self.assertRaisesRegex(ValueError, "not staged"):
            self.notarize(stage=False)
        self.assertEqual(self.tools.commands("ditto"), [])
        self.assertEqual(files_containing(self.root, NOTARY_KEY), [])

    def test_never_stages_the_key_without_the_ram_disk(self):
        build.cleanup(self.work, self.tools, echo=lambda _: None)
        self.work.mkdir()
        for state in ({}, {"ramDisk": "/dev/disk99", "secrets": str(self.secrets)}):
            with self.subTest(state=state):
                build.save_state(self.work, state)
                with self.assertRaisesRegex(ValueError, "not mounted"):
                    self.stage()
        self.assertEqual(files_containing(self.root, NOTARY_KEY), [])
        self.assertFalse(any(call[-1] == REFERENCES["MACOS_NOTARY_KEY"] for call in self.tools.commands("op")),
                         "nothing is read from 1Password before the RAM disk is confirmed")


class VersionTests(TemporaryJob):
    def test_patch_sequence_and_manual_minor_bump(self):
        releases = [{"tag_name": "mac-v1.0-2"}]
        self.assertEqual(build.next_mac_version("1.0", releases), "1.0.1")
        releases += [{"tag_name": "mac-v1.0.1"}, {"tag_name": "mac-v1.0.9"}]
        self.assertEqual(build.next_mac_version("1.0", releases), "1.0.10")
        self.assertEqual(build.next_mac_version("1.1", releases), "1.1.1")
        self.assertEqual(build.next_mac_version("2.0", releases), "2.0.1")
        self.assertEqual(build.next_mac_version("1.0.12", releases), "1.0.13")

    def test_ignores_unpublished_unrelated_and_legacy_tags(self):
        releases = [{"tag_name": "mac-v1.0.99", "draft": True},
                    {"tag_name": "mac-v1.0.50", "prerelease": True},
                    {"tag_name": "v1.0.30"}, {"tag_name": "mac-v1.0-200"},
                    {"tag_name": "mac-v1.1.20"}]
        self.assertEqual(build.next_mac_version("1.0", releases), "1.0.1")
        for invalid in ("1", "1.0-beta", "1.0.1.2", "01.0"):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                build.next_mac_version(invalid, releases)

    def test_selection_reads_all_release_pages_and_writes_no_git_files(self):
        def run(args, **kwargs):
            if args[0] == "xcodebuild":
                return completed(args, stdout=json.dumps([{"target": "TermLLMMac",
                    "buildSettings": {"MARKETING_VERSION": "1.0"}}]).encode())
            self.assertEqual(args, ["gh", "api", "--paginate", "--slurp",
                                   "repos/owner/repo/releases?per_page=100"])
            return completed(args, stdout=json.dumps([[{"tag_name": "mac-v1.0.1"}],
                                                     [{"tag_name": "mac-v1.0.4"}]]).encode())
        self.assertEqual(build.select_version(self.work, "owner/repo", run), "1.0.5")
        self.assertEqual((self.work / "version.txt").read_text(), "1.0.5\n")

    def test_selected_version_overrides_both_bundles(self):
        (self.work / "version.txt").write_text("1.0.5\n")
        self.prepare()
        settings = (self.work / build.SETTINGS_FILE).read_text()
        self.assertIn("MARKETING_VERSION = 1.0.5\n", settings)
        self.assertIn("CURRENT_PROJECT_VERSION = 7\n", settings)


class PublishTests(AppFixture):
    def test_creates_a_latest_release_for_the_commit(self):
        summary = self.work / "summary.md"
        tag = build.publish(self.app, self.work, "owner/repo", SHA, self.tools,
                            environ={"GITHUB_STEP_SUMMARY": str(summary)}, echo=lambda _: None)
        self.assertEqual(tag, "mac-v1.0.1")
        archive = self.work / "term-llm-macos-1.0.1.zip"
        create = self.tools.commands("gh", "release", "create")[0]
        self.assertEqual(create[3:5], ["mac-v1.0.1", str(archive)])
        for flag, value in (("--repo", "owner/repo"), ("--target", SHA), ("--title", "term-llm for Mac 1.0.1")):
            self.assertEqual(create[create.index(flag) + 1], value)
        self.assertIn("--latest", create)
        notes = Path(create[create.index("--notes-file") + 1]).read_text()
        self.assertIn(hashlib.sha256(archive.read_bytes()).hexdigest(), notes)
        self.assertIn("macOS 14.0 or later", notes)
        self.assertIn("releases/tag/mac-v1.0.1", summary.read_text())

    def test_rejects_untrusted_arguments(self):
        for repository, commit in (("owner/repo", "main"), ("owner/repo;x", SHA), ("", SHA)):
            with self.subTest(repository=repository, commit=commit), self.assertRaises(ValueError):
                build.publish(self.app, self.work, repository, commit, self.tools, environ={})
        self.assertEqual(self.tools.calls, [])


class MainTests(TemporaryJob):
    def test_refuses_to_run_outside_a_job_directory(self):
        stderr = io.StringIO()
        environ = dict(self.environ, RUNNER_TEMP="")
        with mock.patch("sys.stderr", stderr):
            code = build.main(["--work-dir", str(self.work), "cleanup"], run=self.tools, environ=environ)
        self.assertEqual(code, 1)
        self.assertIn("RUNNER_TEMP", stderr.getvalue())
        self.assertEqual(self.tools.calls, [])

    def test_errors_are_reported_without_secret_values(self):
        self.tools.import_password = "different"
        stderr = io.StringIO()
        with mock.patch("sys.stderr", stderr), mock.patch("sys.stdout", io.StringIO()):
            code = build.main(["--work-dir", str(self.work), "prepare", "--build-number", "7",
                               "--profiles-dir", str(self.profiles_dir),
                               "--profiles-destination", str(self.destination)],
                              run=self.tools, environ=self.environ)
        self.assertEqual(code, 1)
        for secret in (P12_PASSWORD, TOKEN, "p12 bytes"):
            self.assertNotIn(secret, stderr.getvalue())

    def test_token_is_removed_from_the_inherited_environment(self):
        with mock.patch.dict(os.environ, {build.OP_TOKEN: TOKEN}):
            source = build.OnePassword(os.environ, self.tools)
            self.assertNotIn(build.OP_TOKEN, os.environ)
        self.assertEqual(source.token, TOKEN)


if __name__ == "__main__":
    unittest.main()
