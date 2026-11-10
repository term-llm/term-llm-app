"""Sparkle release contract. No configurable production endpoint or remote shell."""
import base64
import hashlib
import os
import plistlib
from pathlib import Path
import re
import shlex
import tarfile
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

FEED = "https://term-llm.com/mac/appcast.xml"
BASE = "https://term-llm.com/mac/"
HOST = "143.198.76.107"
DESTINATION = "term-llm-updates@143.198.76.107:./"
HELP = "docs/SELF-HOSTED-CI.md#sparkle-updates"
TOOLS_URL = "https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz"
TOOLS_SHA256 = "1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", NS)
MAX_FEED = 1024 * 1024
MAX_HISTORY = 20
ARCHIVE_URL = re.compile(re.escape(BASE) +
                         r"term-llm-macos-([0-9]+(?:\.[0-9]+)*)-([1-9][0-9]*)-([0-9a-f]{64})\.zip")
FILES = ("sparkle-key", "downloads-key", "downloads-known-hosts")
# term-llm.com sits behind Cloudflare, which rejects urllib's default
# "Python-urllib/x.y" User-Agent with HTTP 403. Identify the publisher instead.
USER_AGENT = "term-llm-app-ci/1.0 (Sparkle publisher)"
_opener = urllib.request.build_opener()
_opener.addheaders = [("User-Agent", USER_AGENT)]
urllib.request.install_opener(_opener)


def decoded(value, lengths):
    try:
        raw = base64.b64decode(value.strip(), validate=True)
    except ValueError:
        raise ValueError(f"Invalid Sparkle base64 key/signature ({HELP})") from None
    if len(raw) not in lengths:
        raise ValueError(f"Invalid Sparkle key/signature length ({HELP})")
    return raw


def prepare(work, source, secrets_dir, run):
    """Read and validate all four fields before archive; persist only to RAM."""
    try:
        public = source.read("SPARKLE_PUBLIC_KEY", secrets_dir).strip()
        private = source.read("SPARKLE_PRIVATE_KEY", secrets_dir).strip()
        ssh = source.read("DOWNLOADS_SSH_PRIVATE_KEY", secrets_dir)
        hosts = source.read("DOWNLOADS_SSH_KNOWN_HOSTS", secrets_dir)
        decoded(public, (32,))
        decoded(private, (32, 96))
        if not ssh.strip().startswith(b"-----BEGIN OPENSSH PRIVATE KEY-----"):
            raise ValueError("SSH private key must be an unencrypted OpenSSH key")
        lines = hosts.decode("ascii").splitlines()
        if not lines or any(not re.fullmatch(
                r"(?:143\.198\.76\.107|\[143\.198\.76\.107\]:22) (?:ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa) [A-Za-z0-9+/]+={0,2}(?: .*)?", line)
                for line in lines):
            raise ValueError("known hosts must explicitly pin 143.198.76.107:22")
        for name, data in zip(FILES, (private + b"\n", ssh, hosts)):
            path = secrets_dir / name
            path.unlink(missing_ok=True)
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(data)
        # New Sparkle exports contain a 32-byte seed; legacy exports are 96
        # bytes. Validate the actual signature, not a presumed key-file layout.
        probe = work / "sparkle-key-check.bin"
        probe.write_bytes(b"term-llm CI Sparkle key consistency check\n")
        try:
            signed = run([str(work / "sparkle-tools/sign_update"), "--ed-key-file",
                          str(secrets_dir / FILES[0]), "-p", str(probe)])
            signature = signed.stdout.decode("ascii").strip()
            decoded(signature.encode(), (64,))
            run(["swift", str(Path(__file__).with_name("verify-sparkle-key.swift")),
                 public.decode("ascii"), signature, str(probe)])
        finally:
            probe.unlink(missing_ok=True)
        # -P empty forbids an encrypted key from causing an interactive prompt.
        run(["ssh-keygen", "-y", "-P", "", "-f", str(secrets_dir / FILES[1])])
        run(["ssh-keygen", "-l", "-f", str(secrets_dir / FILES[2])])
        (work / "sparkle-public-key.txt").write_bytes(public)
        return public.decode("ascii")
    except Exception:
        # Never include op/tool output: malformed secret material may be echoed there.
        raise ValueError(f"Missing or invalid Sparkle/downloads credentials; see {HELP}") from None


def fetch(url, limit, allow_missing=False):
    try:
        with urllib.request.urlopen(url, timeout=60) as response:
            if response.geturl() != url:
                raise ValueError("Release downloads must not redirect")
            data = response.read(limit + 1)
    except urllib.error.HTTPError as error:
        if allow_missing and error.code == 404 and error.geturl() == url:
            return None
        raise ValueError(f"Release download failed with HTTP {error.code}") from None
    if len(data) > limit:
        raise ValueError("Release download exceeds size bound")
    return data


def fetch_tools(work):
    # GitHub release assets redirect to their CDN; verify bytes, not redirect host.
    with urllib.request.urlopen(TOOLS_URL, timeout=60) as response:
        data = response.read(100 * 1024 * 1024 + 1)
    if hashlib.sha256(data).hexdigest() != TOOLS_SHA256:
        raise ValueError("Pinned Sparkle 2.10.1 tools SHA-256 mismatch")
    archive = work / "sparkle-tools.tar.xz"
    archive.write_bytes(data)
    tools = work / "sparkle-tools"
    tools.mkdir()
    with tarfile.open(archive) as bundle:
        # Extract only the executable we use, never arbitrary archive paths/symlinks.
        member = bundle.getmember("./bin/sign_update")
        if not member.isfile() or member.size > 20 * 1024 * 1024:
            raise ValueError("Unexpected Sparkle sign_update archive member")
        (tools / "sign_update").write_bytes(bundle.extractfile(member).read())
    (tools / "sign_update").chmod(0o700)


def history(previous, build_number):
    items = []
    if previous is not None:
        if len(previous) > MAX_FEED or b"<!DOCTYPE" in previous.upper() or b"<!ENTITY" in previous.upper():
            raise ValueError("Unsafe or oversized existing appcast")
        try:
            root = ET.fromstring(previous)
        except ET.ParseError:
            raise ValueError("Malformed existing appcast") from None
        channel = root.find("channel")
        if root.tag != "rss" or channel is None:
            raise ValueError("Malformed existing appcast")
        items = channel.findall("item")
        if len(items) > MAX_HISTORY:
            raise ValueError("Existing appcast exceeds history limit")
        seen = set()
        for item in items:
            enclosure = item.find("enclosure")
            version = item.findtext(f"{{{NS}}}version")
            version = version or (enclosure.get(f"{{{NS}}}version") if enclosure is not None else None)
            if not version or not re.fullmatch(r"[1-9][0-9]*", version) or version in seen:
                raise ValueError("Existing feed has invalid or duplicate builds")
            match = ARCHIVE_URL.fullmatch(enclosure.get("url", "")) if enclosure is not None else None
            marketing = item.findtext(f"{{{NS}}}shortVersionString", "")
            if not match or match.group(1, 2) != (marketing, version):
                raise ValueError("Existing feed has invalid enclosure")
            decoded(enclosure.get(f"{{{NS}}}edSignature", "").encode(), (64,))
            if not re.fullmatch(r"[1-9][0-9]{0,19}", enclosure.get("length", "")):
                raise ValueError("Existing feed has invalid enclosure length")
            minimum = item.findtext(f"{{{NS}}}minimumSystemVersion", "")
            if not re.fullmatch(r"[0-9]{1,3}(?:\.[0-9]{1,3}){0,2}", minimum) or int(minimum.split(".")[0]) < 14:
                raise ValueError("Existing feed must require macOS 14 or later")
            seen.add(version)
            if int(version) >= int(build_number):
                raise ValueError("Refusing duplicate build or downgrade of appcast")
        items.sort(key=lambda item: int(item.findtext(f"{{{NS}}}version") or item.find("enclosure").get(f"{{{NS}}}version")), reverse=True)
    return items


def public_asset(metadata, digest):
    name = f"term-llm-macos-{metadata['version']}-{metadata['build']}-{digest}.zip"
    if not ARCHIVE_URL.fullmatch(BASE + name):
        raise ValueError("Invalid content-addressed public archive name")
    return name


def appcast(previous, metadata, signature, length):
    decoded(signature.encode(), (64,))
    items = history(previous, metadata["build"])
    match = ARCHIVE_URL.fullmatch(BASE + metadata["publicAsset"])
    if not match or match.group(1, 2) != (metadata["version"], metadata["build"]):
        raise ValueError("Invalid public archive URL")
    root = ET.Element("rss", version="2.0")
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "term-llm for Mac"
    ET.SubElement(channel, "link").text = FEED
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = metadata["title"]
    for name, value in (("version", metadata["build"]), ("shortVersionString", metadata["version"]), ("minimumSystemVersion", "14.0")):
        ET.SubElement(item, f"{{{NS}}}{name}").text = value
    # The enclosing appcast is signed after serialization, covering these short
    # inline notes without a private GitHub link or another public endpoint.
    ET.SubElement(item, "description").text = (
        f"term-llm for Mac {metadata['version']} (build {metadata['build']}). "
        "Developer ID signed and notarized. Requires macOS 14 or later.")
    ET.SubElement(item, "enclosure", {"url": BASE + metadata["publicAsset"], "length": str(length), "type": "application/octet-stream", f"{{{NS}}}edSignature": signature})
    channel.extend(items[:MAX_HISTORY - 1])
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def verify_app(app, work):
    info = plistlib.loads((Path(app) / "Contents/Info.plist").read_bytes())
    if info.get("SUFeedURL") != FEED or info.get("SUPublicEDKey") != (work / "sparkle-public-key.txt").read_text():
        raise ValueError(f"Archived app must use the production feed and staged public key; see {HELP}")

    required = {"SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True,
                "SUSignedFeedFailureExpirationInterval": 0, "SUAllowsAutomaticUpdates": False}
    for name, expected in required.items():
        actual = info.get(name)
        if type(actual) is not type(expected) or actual != expected:
            raise ValueError(f"Archived app has unsafe Sparkle policy {name}; see {HELP}")


def verify_previous(previous, work, secrets_dir, run):
    # Bound untrusted content before even handing it to the pinned verifier.
    if len(previous) > MAX_FEED:
        raise ValueError(f"Existing appcast exceeds size bound; see {HELP}")
    path = work / "previous-appcast.xml"
    path.write_bytes(previous)
    try:
        run([str(work / "sparkle-tools/sign_update"), "--verify", "--ed-key-file",
             str(secrets_dir / FILES[0]), str(path)])
    except Exception:
        raise ValueError(f"Existing appcast signature verification failed; see {HELP}") from None
    finally:
        path.unlink(missing_ok=True)


def load_history(work, secrets_dir, run, build_number):
    previous = fetch(FEED, MAX_FEED, allow_missing=True)
    if previous is not None:
        verify_previous(previous, work, secrets_dir, run)
    return previous, history(previous, build_number)


def advance_version(work, secrets_dir, run, selected, build_number):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", selected):
        raise ValueError("Release version must be major.minor.patch")
    _, items = load_history(work, secrets_dir, run, build_number)
    major, minor, patch = map(int, selected.split("."))
    for item in items:
        marketing = item.findtext(f"{{{NS}}}shortVersionString", "")
        if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", marketing):
            raise ValueError("Existing feed has invalid marketing version")
        old_major, old_minor, old_patch = map(int, marketing.split("."))
        if (major, minor) == (old_major, old_minor):
            patch = max(patch, old_patch + 1)
    return f"{major}.{minor}.{patch}"


def file_digest(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_public_archive(url, expected_digest, expected_length):
    """Stream at most the exact ZIP length + 1 byte; never trust HEAD/cache metadata."""
    digest = hashlib.sha256()
    count = 0
    try:
        with urllib.request.urlopen(url, timeout=60) as response:
            if response.geturl() != url:
                raise ValueError("Public archive must not redirect")
            while True:
                chunk = response.read(min(65536, expected_length + 1 - count))
                if not chunk:
                    break
                count += len(chunk)
                if count > expected_length:
                    raise ValueError("Public archive exceeds expected size")
                digest.update(chunk)
        if count != expected_length or digest.hexdigest() != expected_digest:
            raise ValueError("Public archive bytes do not match signed ZIP")
    except Exception:
        raise ValueError(f"Public archive HTTPS verification failed; see {HELP}") from None


def publish(app, work, metadata, secrets_dir, run):
    """Upload immutable payloads before the feed, each rsync using atomic rename."""
    verify_app(app, work)
    archive = work / metadata["asset"]
    if archive.exists():
        raise ValueError("Release archive already exists; refusing to rewrite")
    previous, _ = load_history(work, secrets_dir, run, metadata["build"])
    run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)])
    digest = file_digest(archive)
    metadata = {**metadata, "publicAsset": public_asset(metadata, digest)}
    signer = str(work / "sparkle-tools/sign_update")
    def sign(path):
        # Never propagate sign_update errors containing key material.
        try:
            result = run([signer, "--ed-key-file", str(secrets_dir / FILES[0]), "-p", str(path)])
            return result.stdout.decode().strip()
        except Exception:
            raise ValueError(f"Sparkle signing failed; see {HELP}") from None
    signature = sign(archive)
    feed = work / "appcast.xml"
    feed.write_bytes(appcast(previous, metadata, signature, archive.stat().st_size))
    try:
        run([signer, "--ed-key-file", str(secrets_dir / FILES[0]), str(feed)])
    except Exception:
        raise ValueError(f"Sparkle appcast signing failed; see {HELP}") from None
    ssh = shlex.join(["ssh", "-F", "/dev/null", "-p", "22", "-i", str(secrets_dir / FILES[1]),
                      "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none", "-o", "ForwardAgent=no",
                      "-o", "ClearAllForwardings=yes", "-o", "PasswordAuthentication=no",
                      "-o", "KbdInteractiveAuthentication=no",
                      "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                      "-o", "UserKnownHostsFile=" + str(secrets_dir / FILES[2]), "-o", "GlobalKnownHostsFile=/dev/null", "-o", "ConnectTimeout=30",
                      "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"])
    def upload(path, destination, immutable=False):
        try:
            # The runner uses macOS openrsync: no -r (sent to the server as
            # --dirs, which rrsync rejects) and only its relative --chmod form.
            run(["rsync", "-t", "--checksum", "--perms", "--chmod=Fu=rw,Fgo=r",
                 *(["--ignore-existing"] if immutable else []), "-e", ssh, str(path), destination])
        except Exception:
            raise ValueError(f"Sparkle upload failed; see {HELP}") from None
    upload(archive, DESTINATION + metadata["publicAsset"], immutable=True)
    verify_public_archive(BASE + metadata["publicAsset"], digest, archive.stat().st_size)
    upload(feed, DESTINATION)
    # GitHub publication must consume these exact bytes, never run ditto again.
    (work / "sparkle-published.sha256").write_text(digest)
