"""Read-only simulator signature and linked-entitlement verification.

Xcode owns ALL signatures and Info.plists, including main app/NSE. Simulator
Keychain identity uses the linked __TEXT,__entitlements section. This module
never executes codesign --sign or mutates any built product.
"""
import hashlib
import plistlib
from pathlib import Path
import struct
import subprocess

from contract import require

PREFIX = "SIMULATOR."
SHARED_GROUP = PREFIX + "com.termllm.peer.capture.shared"


def entitlements(bundle_id):
    require(isinstance(bundle_id, str) and bundle_id.startswith("com.termllm.app"), "Unexpected executable bundle identifier")
    identifier = PREFIX + bundle_id
    return {"application-identifier": identifier,
            "keychain-access-groups": [identifier, SHARED_GROUP],
            "com.apple.security.get-task-allow": True}


def build_entitlements(path):
    # Xcode expands PRODUCT_BUNDLE_IDENTIFIER separately for every target and
    # emits both signing .xcent and linker .xcent-Simulated payloads.
    path.write_bytes(plistlib.dumps({
        "application-identifier": PREFIX + "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "keychain-access-groups": [PREFIX + "$(PRODUCT_BUNDLE_IDENTIFIER)", SHARED_GROUP],
        "com.apple.security.get-task-allow": True}))


def embedded_entitlements(data):
    """Read actual 64-bit Mach-O simulator section(s), including universal files."""
    slices = []
    if data[:4] == b"\xca\xfe\xba\xbe":
        count = struct.unpack_from(">I", data, 4)[0]
        require(count <= 16, "Invalid universal simulator executable")
        for index in range(count):
            offset, size = struct.unpack_from(">II", data, 8 + index * 20 + 8)
            slices.append(data[offset:offset + size])
    else:
        slices = [data]
    values = []
    for image in slices:
        require(image[:4] == b"\xcf\xfa\xed\xfe", "Expected 64-bit simulator Mach-O executable")
        commands = struct.unpack_from("<I", image, 16)[0]
        position = 32
        found = None
        for _ in range(commands):
            command, length = struct.unpack_from("<II", image, position)
            require(length >= 8 and position + length <= len(image), "Invalid simulator load command")
            if command == 0x19:  # LC_SEGMENT_64
                count = struct.unpack_from("<I", image, position + 64)[0]
                require(72 + count * 80 <= length, "Invalid simulator section table")
                for index in range(count):
                    section = position + 72 + index * 80
                    name = image[section:section + 16].rstrip(b"\0")
                    segment = image[section + 16:section + 32].rstrip(b"\0")
                    if name == b"__entitlements" and segment == b"__TEXT":
                        size = struct.unpack_from("<Q", image, section + 40)[0]
                        offset = struct.unpack_from("<I", image, section + 48)[0]
                        require(offset + size <= len(image), "Invalid simulator entitlement section")
                        found = plistlib.loads(image[offset:offset + size].rstrip(b"\0"))
            position += length
        require(found is not None, "Simulator executable lacks linked __TEXT,__entitlements; unsigned keychain access is not accepted")
        values.append(found)
    return values


def signature_state(path):
    """Read-only proof of actual entitlements, CodeDirectory and executable."""
    result = subprocess.run(["codesign", "--display", "--entitlements", ":-", str(path)], check=True, capture_output=True)
    actual = plistlib.loads(result.stdout) if result.stdout.strip() else {}
    detail = subprocess.run(["codesign", "--display", "--verbose=4", str(path)], check=True, capture_output=True)
    info_path = path / "Info.plist" if path.is_dir() else None
    info = plistlib.loads(info_path.read_bytes()) if info_path and info_path.is_file() else {}
    binary = path / info.get("CFBundleExecutable", "") if path.is_dir() else path
    return dict(entitlements=actual,
                signature_details=(detail.stdout + detail.stderr).decode(errors="replace")[:12000],
                binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest() if binary.is_file() else None,
                info_plist_sha256=hashlib.sha256(info_path.read_bytes()).hexdigest() if info_path and info_path.is_file() else None)


def sign_products(products, private, provenance):
    """Historical entry-point name; performs NO post-build signing or mutation."""
    products = products.resolve()
    require(not any(products.rglob("embedded.mobileprovision")), "Simulator capture must not use provisioning profiles")
    app = products / "TermLLM.app"
    require(app.is_dir(), "Main simulator app missing")
    app_info = plistlib.loads((app / "Info.plist").read_bytes())
    require(app_info.get("CFBundleIdentifier") == "com.termllm.app", "Unexpected main simulator app identifier")
    bundles = [p for p in products.rglob("*") if p.is_dir() and p.suffix in (".app", ".appex", ".xctest", ".framework")]
    libraries = [p for p in products.rglob("*.dylib") if p.is_file()]
    paths = sorted(bundles + libraries, key=str)
    records = []
    provenance.update(signing_scope="none-read-only-verification", products=records)
    for path in paths:
        require(path.resolve().is_relative_to(products), "Refusing to inspect code outside simulator products")
        prior = signature_state(path)
        # ONLY SDK frameworks/libraries may have upstream resource envelopes
        # invalidated by Xcode's normal stripping/copy phase (c8d5680). App,
        # NSE, runner and .xctest resources receive strict validation unchanged.
        sdk_copy = path.suffix in (".framework", ".dylib")
        args = ["codesign", "--verify", "--strict"]
        if sdk_copy:
            args.append("--ignore-resources")
        subprocess.run([*args, str(path)], check=True, capture_output=True)
        final = signature_state(path)
        record = dict(path=str(path.relative_to(products)), action="preserved-xcode-code",
                      before=prior, **final, verified=True,
                      resource_envelope_validated=not sdk_copy)
        records.append(record)
        require(final == prior, "Xcode-generated signature, executable or Info.plist changed during verification")
        if path == app:
            expected = entitlements(app_info["CFBundleIdentifier"])
            linked = embedded_entitlements((app / app_info["CFBundleExecutable"]).read_bytes())
            record["linked_entitlements"] = linked
            for item in linked:
                require(item.get("application-identifier") == expected["application-identifier"], "Linked simulator application identifier mismatch")
                require(item.get("keychain-access-groups") == expected["keychain-access-groups"], "Linked simulator keychain groups mismatch")
            # Physical entitlements are recorded, never replaced with the
            # simulated application-identifier/keychain payload. Empty is normal.
    provenance.update(namespace=PREFIX, shared_keychain_group=SHARED_GROUP,
                      preserved_validation="strict signatures/resources; resource ignore ONLY on preserved SDK frameworks/libraries",
                      apple_identity=False, provisioning_profile=False, osstatus_measured=False)
