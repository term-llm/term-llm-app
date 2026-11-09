#!/usr/bin/env python3
"""Developer ID sign, notarize and publish term-llm.app inside one CI job.

Secrets come from 1Password and never touch the runner's disk. `op read`
returns each value straight into this process's memory, authenticated by a
read-only service account token that only `op` is given. The job mounts an
owner-only RAM disk (memory only; anything macOS pages out goes to its
encrypted swap), and the only secret material ever stored lands there: a job
keychain holding the Developer ID key, piped in from memory and imported as
non-extractable, and the notary API key. `cleanup` removes exactly what
`prepare` added: the keychain and its search-list entry, the provisioning
profiles it installed, the RAM disk and the work directory. Secret values never
appear in anything this script prints.
"""
import argparse
import base64
import binascii
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
TEAM_ID = "B6BAJ46A72"
APP_NAME = "term-llm.app"
EXTENSION_PATH = Path("Contents/PlugIns/TermLLMNotificationService.appex")
SHARED_GROUP = "group.com.termllm.app.shared"
KEYCHAIN_GROUP = f"{TEAM_ID}.com.termllm.app.shared"
# Xcode target name -> (bundle identifier, committed Developer ID profile).
PROFILES = {
    "TermLLMMac": ("com.termllm.app", "term-llm.provisionprofile"),
    "TermLLMMacNotificationService": ("com.termllm.app.NotificationService",
                                      "TermLLMNotificationService.provisionprofile"),
}
APP_TARGET = "TermLLMMac"
DEFAULT_PROFILES_DIR = ROOT / "TermLLMMac" / "DeveloperID"
XCODE_PROFILES_DIR = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
WORK_PREFIX = "term-llm-mac-release."
SECRETS_DIR = "secrets"  # RAM disk mount point inside the work directory
RAM_DISK_SECTORS = 16384  # 8 MiB
RAM_DISK_VOLUME = "TermLLMSigning"
KEYCHAIN_FILE = "signing.keychain-db"
NOTARY_KEY_FILE = "AuthKey.p8"
NOTARY_IDS_FILE = "notary.json"
STATE_FILE = "signing-state.json"
SETTINGS_FILE = "DeveloperID.xcconfig"
EXPORT_OPTIONS_FILE = "ExportOptions.plist"
# Keychains and RAM disks a job of this workflow created, including ones left by
# a killed job. One runner per Mac, so any other match is stale.
_JOB_SECRETS = re.escape(WORK_PREFIX) + r"[^/]+/" + SECRETS_DIR
JOB_KEYCHAIN = re.compile(r"/" + _JOB_SECRETS + "/" + re.escape(KEYCHAIN_FILE) + r"$")
JOB_MOUNT = re.compile(r"^(/dev/disk[0-9]+) on (/.*/" + _JOB_SECRETS + r") \((.*)\)$")
UUID = re.compile(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}")
IDENTITY_LINE = re.compile(r'^\s*\d+\)\s+([0-9A-F]{40})\s+"([^"\n]+)"\s*$')
NOTARY_TIMEOUT = "45m"
SECRET_HELP = "see docs/SELF-HOSTED-CI.md, Notarized Mac builds"
OP_TOKEN = "OP_SERVICE_ACCOUNT_TOKEN"
OP_CONFIG_DIR = "op"  # on the RAM disk, so `op` never writes to the user's config
# Each secret is read from the 1Password reference in <NAME>_REF.
SECRET_NAMES = ("MACOS_SIGN_P12", "MACOS_SIGN_PASSWORD", "MACOS_NOTARY_KEY", "MACOS_NOTARY_KEY_ID",
                "MACOS_NOTARY_ISSUER_ID")


class CommandError(RuntimeError):
    """A tool failed. Only the tool and subcommand are reported, never its arguments."""

    def __init__(self, args, result):
        detail = (result.stderr or b"").decode("utf-8", "replace").strip() or \
                 (result.stdout or b"").decode("utf-8", "replace").strip()
        super().__init__(f"{' '.join(args[:2])} failed with exit status {result.returncode}"
                         + (f": {detail[-2000:]}" if detail else ""))


def _run(run, args, check=True, input=None, env=None):
    result = run(list(args), capture_output=True, check=False, input=input, env=env)
    if check and result.returncode != 0:
        raise CommandError(args, result)
    return result


def _text(data):
    return (data or b"").decode("utf-8", "replace")


def _write_private(path, data):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(data)


class OnePassword:
    """Reads 1Password secret references with a service account token only `op` sees.

    Construct it before running anything else: it removes the token from the
    environment that every other child process inherits.
    """

    def __init__(self, environ, run):
        self.token = environ.get(OP_TOKEN, "").strip()
        # Drop every OP_* setting (Connect hosts, accounts, sessions) so `op` can only
        # use this service account.
        self.environ = {key: value for key, value in environ.items() if not key.startswith("OP_")}
        self.references = {name: environ.get(f"{name}_REF", "").strip() for name in SECRET_NAMES}
        self.run = run
        if environ is os.environ:
            os.environ.pop(OP_TOKEN, None)

    def read(self, name, secrets_dir):
        if not self.token:
            raise ValueError(f"{OP_TOKEN} is not set ({SECRET_HELP})")
        reference = self.references.get(name, "")
        if not reference.startswith("op://"):
            raise ValueError(f"{name}_REF must be a 1Password op:// secret reference ({SECRET_HELP})")
        config = Path(secrets_dir) / OP_CONFIG_DIR
        config.mkdir(mode=0o700, exist_ok=True)
        result = _run(self.run, ["op", "read", "--no-newline", "--cache=false", "--config", str(config), reference],
                      env={**self.environ, OP_TOKEN: self.token})
        if not result.stdout:
            raise ValueError(f"1Password returned nothing for {name}_REF")
        return result.stdout


def _decoded(value, looks_right):
    """Accept the value as stored, or base64 of it (the format GitHub secrets used)."""
    if looks_right(value):
        return value
    try:
        decoded = base64.b64decode(b"".join(value.split()), validate=True)
    except (binascii.Error, ValueError):
        decoded = b""
    return decoded if looks_right(decoded) else None


def pkcs12_bytes(value):
    certificate = _decoded(value, lambda data: data[:1] == b"\x30")  # DER SEQUENCE
    if certificate is None:
        raise ValueError("MACOS_SIGN_P12_REF must point at the .p12 file attachment")
    return certificate


def pem_bytes(value):
    key = _decoded(value, lambda data: data.lstrip().startswith(b"-----BEGIN "))
    if key is None:
        raise ValueError("MACOS_NOTARY_KEY_REF must point at the AuthKey .p8 file attachment")
    return key


def text_secret(value, name):
    try:
        text = value.decode("utf-8").strip()
    except UnicodeDecodeError:
        text = ""
    if not text or "\n" in text:
        raise ValueError(f"{name}_REF must point at a single-line field")
    return text


def work_directory(work_dir, runner_temp):
    """Accept only a job-owned directory created directly inside RUNNER_TEMP."""
    if not runner_temp:
        raise ValueError("RUNNER_TEMP is not set; refusing to manage signing state outside a CI job")
    work = Path(work_dir).resolve()
    if work.parent != Path(runner_temp).resolve() or not work.name.startswith(WORK_PREFIX):
        raise ValueError(f"Work directory must be a {WORK_PREFIX}* directory directly inside RUNNER_TEMP")
    return work


def load_state(work):
    path = work / STATE_FILE
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}


def save_state(work, state):
    path = work / STATE_FILE
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


# RAM disk ---------------------------------------------------------------------

def job_mounts(run):
    """Yield (device, mount point, options) for every RAM disk this workflow mounted."""
    for line in _text(_run(run, ["mount"]).stdout).splitlines():
        match = JOB_MOUNT.match(line.strip())
        if match:
            yield match.group(1), match.group(2), [option.strip() for option in match.group(3).split(",")]


def eject(run, device):
    if _run(run, ["diskutil", "eject", device], check=False).returncode != 0:
        _run(run, ["diskutil", "unmountDisk", "force", device], check=False)
        _run(run, ["diskutil", "eject", device])


def secrets_directory(work, run):
    """Return the mounted RAM disk, failing closed so secrets can never land on the SSD."""
    state = load_state(work)
    mount_point = state.get("secrets")
    expected = os.path.realpath(mount_point) if mount_point else None
    for device, mounted, options in job_mounts(run):
        if device == state.get("ramDisk") and os.path.realpath(mounted) == expected:
            if "nobrowse" not in options or "noowners" in options:
                raise ValueError("The signing RAM disk is not mounted owner-only and hidden")
            return Path(mount_point)
    raise ValueError("The signing RAM disk is not mounted; refusing to write secrets to disk")


def attach_ram_disk(work, run):
    """Mount an owner-only, Finder-invisible RAM disk at work/secrets."""
    mount_point = work / SECRETS_DIR
    mount_point.mkdir(mode=0o700)
    output = _text(_run(run, ["diskutil", "image", "attach", "--noMount", f"ram://{RAM_DISK_SECTORS}"]).stdout)
    device = next((token for token in output.split() if re.fullmatch(r"/dev/disk[0-9]+", token)), None)
    if not device:
        raise ValueError("diskutil did not return a RAM disk device")
    state = load_state(work)
    state.update({"ramDisk": device, "secrets": str(mount_point)})
    save_state(work, state)  # recorded before formatting so cleanup can always eject it
    _run(run, ["newfs_hfs", "-v", RAM_DISK_VOLUME, device])
    _run(run, ["diskutil", "mount", "nobrowse", "-mountOptions", "owners", "-mountPoint", str(mount_point), device])
    secrets_dir = secrets_directory(work, run)
    os.chmod(secrets_dir, 0o700)
    return secrets_dir


# Provisioning profiles -------------------------------------------------------

def decode_profile(path, run):
    return plistlib.loads(_run(run, ["security", "cms", "-D", "-i", str(path)]).stdout)


def profile_summary(document, bundle_id, now):
    """Validate one decoded Developer ID profile for this team and bundle."""
    name = document.get("Name") or "unnamed profile"
    if TEAM_ID not in document.get("TeamIdentifier", []):
        raise ValueError(f"{name}: not a profile for team {TEAM_ID}")
    if "OSX" not in document.get("Platform", []):
        raise ValueError(f"{name}: not a macOS profile")
    # Device lists mean development or ad hoc. prepare() also requires the profile to
    # contain the imported Developer ID Application certificate, which pins the type.
    if document.get("ProvisionedDevices"):
        raise ValueError(f"{name}: lists devices, so it is a development profile, not Developer ID")
    if document.get("IsXcodeManaged") is True:
        raise ValueError(f"{name}: is Xcode managed; create a Developer ID profile in the developer portal")
    entitlements = document.get("Entitlements", {})
    identifier = entitlements.get("com.apple.application-identifier") or entitlements.get("application-identifier")
    if identifier != f"{TEAM_ID}.{bundle_id}":
        raise ValueError(f"{name}: profile is for {identifier}, expected {TEAM_ID}.{bundle_id}")
    expires = document.get("ExpirationDate")
    if not isinstance(expires, datetime.datetime) or expires <= now:
        raise ValueError(f"{name}: profile has expired")
    uuid = document.get("UUID", "")
    if not UUID.fullmatch(uuid):
        raise ValueError(f"{name}: profile has no valid UUID")
    certificates = sorted({hashlib.sha1(der).hexdigest().upper() for der in document.get("DeveloperCertificates", [])})
    return {"bundleId": bundle_id, "certificates": certificates, "entitlements": entitlements,
            "name": name, "uuid": uuid}


def install_profiles(profiles_dir, destination, now, run):
    """Validate the committed profiles and install the ones Xcode does not already have."""
    summaries, installed = {}, []
    for target, (bundle_id, filename) in PROFILES.items():
        source = Path(profiles_dir) / filename
        if not source.is_file():
            raise ValueError(f"Missing Developer ID provisioning profile {source} ({SECRET_HELP})")
        summary = profile_summary(decode_profile(source, run), bundle_id, now)
        if target == APP_TARGET and \
                summary["entitlements"].get("com.apple.developer.aps-environment") != "production":
            raise ValueError(f"{summary['name']}: enable Push Notifications for {bundle_id} and regenerate it")
        summaries[target] = summary
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    for target, (_, filename) in PROFILES.items():
        path = destination / f"{summaries[target]['uuid']}.provisionprofile"
        if not path.exists():
            shutil.copyfile(Path(profiles_dir) / filename, path)
            installed.append(str(path))
    return summaries, installed


# Keychain ---------------------------------------------------------------------

def parse_search_list(output):
    paths = []
    for line in output.splitlines():
        line = line.strip()
        if len(line) >= 2 and line[0] == line[-1] == '"':
            line = line[1:-1]
        if line:
            paths.append(line)
    return paths


def search_list(run):
    return parse_search_list(_text(_run(run, ["security", "list-keychains", "-d", "user"]).stdout))


def set_search_list(run, paths):
    if not paths:
        raise ValueError("Refusing to clear the user keychain search list")
    _run(run, ["security", "list-keychains", "-d", "user", "-s", *paths])


def without_job_keychains(paths):
    return [path for path in paths if not JOB_KEYCHAIN.search(path)]


def select_identity(output):
    """Return the single valid Developer ID Application identity for the team."""
    matches = {}
    for line in output.splitlines():
        match = IDENTITY_LINE.match(line)
        if match and match.group(2).startswith("Developer ID Application:") \
                and match.group(2).endswith(f"({TEAM_ID})"):
            matches[match.group(1)] = match.group(2)
    if len(matches) != 1:
        raise ValueError(f"MACOS_SIGN_P12 must contain exactly one valid Developer ID Application "
                         f"identity for team {TEAM_ID}; found {len(matches)}")
    (sha1, name), = matches.items()
    if "//" in name:
        raise ValueError("Unexpected characters in the signing identity name")
    return sha1, name


def import_identity(work, certificate, password, run):
    """Create the RAM-disk keychain, pipe the .p12 into it and put it on the search list."""
    keychain = secrets_directory(work, run) / KEYCHAIN_FILE
    keychain_password = secrets.token_hex(32)
    state = load_state(work)
    state["keychain"] = str(keychain)
    save_state(work, state)  # recorded first so cleanup can always find it

    _run(run, ["security", "create-keychain", "-p", keychain_password, str(keychain)])
    _run(run, ["security", "set-keychain-settings", "-lut", "7200", str(keychain)])
    _run(run, ["security", "unlock-keychain", "-p", keychain_password, str(keychain)])
    # The .p12 travels through a pipe, never a file; -x keeps the key non-extractable.
    _run(run, ["security", "import", "/dev/stdin", "-k", str(keychain), "-f", "pkcs12", "-x", "-P", password,
               "-T", "/usr/bin/codesign"], input=certificate)
    _run(run, ["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s",
               "-k", keychain_password, str(keychain)])

    original = without_job_keychains(search_list(run))
    state["searchList"] = original
    save_state(work, state)
    set_search_list(run, [str(keychain), *original])
    identities = _text(_run(run, ["security", "find-identity", "-v", "-p", "codesigning", str(keychain)]).stdout)
    sha1, name = select_identity(identities)
    state.update({"identity": name, "identitySha1": sha1})
    save_state(work, state)
    return sha1, name


# Build settings -----------------------------------------------------------------

def build_settings(identity_name, summaries, build_number):
    lines = [
        "// Generated by scripts/ci/notarized-mac-build.py for one CI job.",
        "CODE_SIGN_STYLE = Manual",
        f"CODE_SIGN_IDENTITY = {identity_name}",
        f"DEVELOPMENT_TEAM = {TEAM_ID}",
        # Package targets resolve to an empty specifier; only the two signed targets get profiles.
        "PROVISIONING_PROFILE_SPECIFIER = $(TERMLLM_DEVELOPER_ID_PROFILE_$(TARGET_NAME))",
    ]
    lines += [f"TERMLLM_DEVELOPER_ID_PROFILE_{target} = {summary['uuid']}" for target, summary in summaries.items()]
    lines.append(f"CURRENT_PROJECT_VERSION = {build_number}")
    return "\n".join(lines) + "\n"


def export_options(identity_sha1, summaries):
    return {
        "destination": "export",
        "method": "developer-id",
        "provisioningProfiles": {summary["bundleId"]: summary["uuid"] for summary in summaries.values()},
        "signingCertificate": identity_sha1,
        "signingStyle": "manual",
        "teamID": TEAM_ID,
    }


def prepare(work, source, build_number, profiles_dir, profiles_destination, run, now=None):
    if not re.fullmatch(r"[1-9][0-9]{0,8}", str(build_number)):
        raise ValueError("Build number must be a positive integer")
    now = now or datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    # A killed job can leave its RAM disk mounted and its keychain on the search list.
    current = search_list(run)
    kept = without_job_keychains(current)
    if kept and kept != current:
        set_search_list(run, kept)
    for device, _, _ in list(job_mounts(run)):
        eject(run, device)

    summaries, installed = install_profiles(profiles_dir, profiles_destination, now, run)
    state = load_state(work)
    state["installedProfiles"] = installed
    save_state(work, state)
    secrets_dir = attach_ram_disk(work, run)
    certificate = pkcs12_bytes(source.read("MACOS_SIGN_P12", secrets_dir))
    password = text_secret(source.read("MACOS_SIGN_PASSWORD", secrets_dir), "MACOS_SIGN_PASSWORD")
    sha1, name = import_identity(work, certificate, password, run)
    for summary in summaries.values():
        if sha1 not in summary["certificates"]:
            raise ValueError(f"{summary['name']} was not generated for the Developer ID certificate in "
                             f"MACOS_SIGN_P12; regenerate it with that certificate")
    (work / SETTINGS_FILE).write_text(build_settings(name, summaries, build_number), encoding="utf-8")
    with open(work / EXPORT_OPTIONS_FILE, "wb") as handle:
        plistlib.dump(export_options(sha1, summaries), handle)
    return name


# Verification and notarization ------------------------------------------------------

def signed_entitlements(path, run):
    output = _run(run, ["codesign", "-d", "--entitlements", "-", "--xml", str(path)]).stdout
    return plistlib.loads(output) if output.strip() else {}


def verify_signature(app, run):
    """Fail before notarization unless both bundles are Developer ID signed as distributed."""
    app = Path(app)
    _run(run, ["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)])
    for bundle in (app, app / EXTENSION_PATH):
        details = _text(_run(run, ["codesign", "-d", "--verbose=4", str(bundle)]).stderr)
        label = bundle.name
        if "Authority=Developer ID Application:" not in details or f"TeamIdentifier={TEAM_ID}" not in details:
            raise ValueError(f"{label} is not signed with the team's Developer ID Application certificate")
        if not re.search(r"flags=0x[0-9a-f]+\([^)]*runtime", details):
            raise ValueError(f"{label} is not signed with the hardened runtime")
        if "Timestamp=" not in details:
            raise ValueError(f"{label} has no secure timestamp")
        if not (bundle / "Contents/embedded.provisionprofile").is_file():
            raise ValueError(f"{label} has no embedded Developer ID provisioning profile")
        entitlements = signed_entitlements(bundle, run)
        if entitlements.get("com.apple.security.get-task-allow"):
            raise ValueError(f"{label} is signed with the debugging entitlement")
        if KEYCHAIN_GROUP not in entitlements.get("keychain-access-groups", []) or \
                SHARED_GROUP not in entitlements.get("com.apple.security.application-groups", []):
            raise ValueError(f"{label} lost its shared keychain or app group entitlement")
        if bundle == app:
            if entitlements.get("com.apple.developer.aps-environment") != "production":
                raise ValueError(f"{label} must use the production APNs environment")
        elif entitlements.get("com.apple.security.app-sandbox") is not True:
            raise ValueError(f"{label} must stay sandboxed")


def parse_notary_output(output):
    try:
        document = json.loads(_text(output) or "{}")
    except json.JSONDecodeError:
        return {}
    return document if isinstance(document, dict) else {}


def notary_issues(log_document, limit=20):
    issues = log_document.get("issues") or []
    lines = []
    for issue in issues[:limit]:
        lines.append(f"{issue.get('severity', 'issue')}: {issue.get('path', '?')}: {issue.get('message', '')}")
    if len(issues) > limit:
        lines.append(f"... {len(issues) - limit} more")
    return lines


def stage_notary_key(work, source, run):
    """Copy the notary API key from 1Password onto the RAM disk for the notarization step."""
    secrets_dir = secrets_directory(work, run)
    key = pem_bytes(source.read("MACOS_NOTARY_KEY", secrets_dir))
    identifiers = {"keyId": text_secret(source.read("MACOS_NOTARY_KEY_ID", secrets_dir), "MACOS_NOTARY_KEY_ID"),
                   "issuer": text_secret(source.read("MACOS_NOTARY_ISSUER_ID", secrets_dir), "MACOS_NOTARY_ISSUER_ID")}
    for name in (NOTARY_KEY_FILE, NOTARY_IDS_FILE):
        (secrets_dir / name).unlink(missing_ok=True)
    _write_private(secrets_dir / NOTARY_KEY_FILE, key)
    _write_private(secrets_dir / NOTARY_IDS_FILE, json.dumps(identifiers).encode("utf-8"))


def notarize(app, work, run, echo=print):
    """Submit to the notary service, staple the ticket and confirm Gatekeeper accepts it.

    The API key is read from the RAM disk, so this long-running step's
    environment holds no secrets. The key is deleted as soon as it is done.
    """
    app = Path(app)
    secrets_dir = secrets_directory(work, run)
    key_path = secrets_dir / NOTARY_KEY_FILE
    ids_path = secrets_dir / NOTARY_IDS_FILE
    upload = work / "notarization-upload.zip"
    try:
        if not key_path.is_file() or not ids_path.is_file():
            raise ValueError("The notary key was not staged on the RAM disk")
        identifiers = json.loads(ids_path.read_text(encoding="utf-8"))
        auth = ["--key", str(key_path), "--key-id", identifiers["keyId"], "--issuer", identifiers["issuer"]]
        _run(run, ["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(upload)])
        echo(f"Submitting {app.name} to the notary service (waiting up to {NOTARY_TIMEOUT})")
        result = _run(run, ["xcrun", "notarytool", "submit", str(upload), *auth, "--wait",
                            "--timeout", NOTARY_TIMEOUT, "--output-format", "json"], check=False)
        submission = parse_notary_output(result.stdout)
        identifier, status = submission.get("id"), submission.get("status")
        issues = []
        if identifier:
            log_path = work / "notarization-log.json"
            logged = _run(run, ["xcrun", "notarytool", "log", identifier, *auth, str(log_path)], check=False)
            if logged.returncode == 0 and log_path.exists():
                issues = notary_issues(parse_notary_output(log_path.read_bytes()))
        for line in issues:
            echo(line)
        if status != "Accepted":
            detail = _text(result.stderr).strip()
            raise ValueError(f"Notarization {identifier or '(not submitted)'} finished as {status or 'unknown'}"
                             + (f": {detail[-2000:]}" if detail else ""))
        echo(f"Notarization {identifier} accepted")
    finally:
        key_path.unlink(missing_ok=True)
        ids_path.unlink(missing_ok=True)
        upload.unlink(missing_ok=True)
    _run(run, ["xcrun", "stapler", "staple", str(app)])
    _run(run, ["xcrun", "stapler", "validate", str(app)])
    assessment = _run(run, ["spctl", "--assess", "--type", "execute", "--verbose=4", str(app)], check=False)
    verdict = _text(assessment.stderr) + _text(assessment.stdout)
    if "assessments disabled" in verdict:
        echo("warning: Gatekeeper assessments are disabled on this runner; relying on stapler validate")
    elif assessment.returncode != 0 or "source=Notarized Developer ID" not in verdict:
        raise ValueError(f"Gatekeeper does not accept the stapled app as Notarized Developer ID: {verdict.strip()}")
    return identifier


# Publishing ----------------------------------------------------------------------------

def release_metadata(app):
    info = plistlib.loads((Path(app) / "Contents/Info.plist").read_bytes())
    version, build = str(info.get("CFBundleShortVersionString", "")), str(info.get("CFBundleVersion", ""))
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", version) or not re.fullmatch(r"[0-9]+", build):
        raise ValueError(f"Unexpected app version {version!r} ({build!r})")
    return {
        "asset": f"term-llm-macos-{version}-{build}.zip",
        "build": build,
        "minimumSystem": str(info.get("LSMinimumSystemVersion", "")),
        "tag": f"mac-v{version}-{build}",
        "title": f"term-llm for Mac {version} ({build})",
        "version": version,
    }


def release_notes(metadata, commit, digest):
    minimum = f"macOS {metadata['minimumSystem']} or later" if metadata["minimumSystem"] else "macOS"
    return (f"Developer ID signed, notarized and stapled build of {commit} from main.\n\n"
            f"- Requires {minimum}; universal (Apple silicon and Intel).\n"
            f"- SHA-256 of `{metadata['asset']}`: `{digest}`\n")


def publish(app, work, repository, commit, run, environ=os.environ, echo=print):
    if not re.fullmatch(r"[0-9a-f]{40}", commit or ""):
        raise ValueError("Commit must be a full SHA")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository or ""):
        raise ValueError("Repository must be owner/name")
    metadata = release_metadata(app)
    archive = work / metadata["asset"]
    _run(run, ["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)])
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    notes = work / "release-notes.md"
    notes.write_text(release_notes(metadata, commit, digest), encoding="utf-8")
    created = _run(run, ["gh", "release", "create", metadata["tag"], str(archive), "--repo", repository,
                         "--target", commit, "--title", metadata["title"], "--notes-file", str(notes),
                         "--latest"])
    url = _text(created.stdout).strip()
    echo(f"Published {metadata['title']}: {url}")
    summary = environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(f"Published [{metadata['title']}]({url}) (`{metadata['asset']}`, SHA-256 `{digest}`)\n")
    return metadata["tag"]


# Cleanup ---------------------------------------------------------------------------------

def unmounted_job_ram_disk(run, device):
    """True only for an unmounted RAM disk of this job's size, never a reused device number."""
    result = _run(run, ["diskutil", "info", "-plist", device], check=False)
    if result.returncode != 0:
        return False
    try:
        info = plistlib.loads(result.stdout)
    except plistlib.InvalidFileException:
        return False
    return (info.get("BusProtocol") == "Disk Image" and not info.get("MountPoint")
            and info.get("TotalSize") == RAM_DISK_SECTORS * 512)


def cleanup(work, run, echo=print):
    """Remove the keychain and its search-list entry, installed profiles, the RAM disk and work directory."""
    state = load_state(work) if work.exists() else {}
    errors = []
    try:
        current = search_list(run)
        kept = without_job_keychains(current) or without_job_keychains(state.get("searchList", []))
        if kept and kept != current:
            set_search_list(run, kept)
        elif not kept:
            errors.append("keychain search list would be empty; left unchanged")
    except (CommandError, ValueError) as error:
        errors.append(str(error))
    keychain = state.get("keychain")
    if keychain and Path(keychain).exists():
        try:
            _run(run, ["security", "delete-keychain", keychain])
        except CommandError as error:
            errors.append(str(error))
    for profile in state.get("installedProfiles", []):
        Path(profile).unlink(missing_ok=True)
    # Ejecting destroys the RAM disk's contents, including anything a failed step left there.
    try:
        devices = [device for device, _, _ in job_mounts(run)]
        if state.get("ramDisk") and state["ramDisk"] not in devices and unmounted_job_ram_disk(run, state["ramDisk"]):
            devices.append(state["ramDisk"])
        for device in devices:
            try:
                eject(run, device)
            except CommandError as error:
                errors.append(str(error))
        if any(True for _ in job_mounts(run)):
            errors.append("a signing RAM disk is still mounted")
    except CommandError as error:
        errors.append(str(error))
    shutil.rmtree(work, ignore_errors=True)
    if work.exists():
        errors.append(f"could not remove {work}")
    for error in errors:
        echo(f"cleanup: {error}")
    return not errors


def main(argv=None, run=subprocess.run, environ=os.environ):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare_command = commands.add_parser("prepare", help="Install profiles, import the identity, write settings")
    prepare_command.add_argument("--build-number", required=True)
    prepare_command.add_argument("--profiles-dir", default=str(DEFAULT_PROFILES_DIR))
    prepare_command.add_argument("--profiles-destination", default=str(XCODE_PROFILES_DIR))
    commands.add_parser("stage-notary-key", help="Copy the notary API key onto the RAM disk")
    for name in ("verify", "notarize"):
        commands.add_parser(name).add_argument("--app", required=True)
    publish_command = commands.add_parser("publish", help="Create the GitHub release")
    publish_command.add_argument("--app", required=True)
    publish_command.add_argument("--repository", required=True)
    publish_command.add_argument("--commit", required=True)
    commands.add_parser("cleanup", help="Remove everything prepare added")
    options = parser.parse_args(argv)

    # Before any child process starts: only `op` may inherit the service account token.
    source = OnePassword(environ, run)
    try:
        work = work_directory(options.work_dir, environ.get("RUNNER_TEMP"))
        if options.command == "prepare":
            name = prepare(work, source, options.build_number, options.profiles_dir,
                           options.profiles_destination, run)
            print(f"Signing with {name}")
        elif options.command == "verify":
            verify_signature(options.app, run)
            print("Developer ID signature, hardened runtime, timestamps and entitlements verified")
        elif options.command == "stage-notary-key":
            stage_notary_key(work, source, run)
            print("Notary key staged on the RAM disk")
        elif options.command == "notarize":
            notarize(options.app, work, run)
        elif options.command == "publish":
            publish(options.app, work, options.repository, options.commit, run, environ)
        else:
            return 0 if cleanup(work, run) else 1
    except (ValueError, OSError, CommandError, plistlib.InvalidFileException) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
