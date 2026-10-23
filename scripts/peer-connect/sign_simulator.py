"""Ad-hoc simulator signing only: no Apple identity, profile or memory keychain.

Xcode must link simulator __TEXT,__entitlements (keychain checks use these).
Post-build codesign normalizes each executable bundle's signature as well.
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


def sign_products(products, private, provenance):
    """Inside-out signing; verify actual main-app linked and signed privileges."""
    products = products.resolve()
    require(not any(products.rglob("embedded.mobileprovision")), "Simulator capture must not use provisioning profiles")
    bundles = [p for p in products.rglob("*") if p.is_dir() and p.suffix in (".app", ".appex", ".xctest", ".framework")]
    libraries = [p for p in products.rglob("*.dylib") if p.is_file()]
    records = []
    for index, path in enumerate(sorted(bundles + libraries, key=lambda p: (-len(p.parts), str(p)))):
        require(path.resolve().is_relative_to(products), "Refusing to sign outside simulator products")
        info_path = path / "Info.plist" if path.is_dir() else None
        info = plistlib.loads(info_path.read_bytes()) if info_path and info_path.is_file() else {}
        # XCTest bundles are loaded libraries (MH_BUNDLE), not processes.
        # Their hosting app/runner owns Keychain privileges; codesign does not
        # retain process entitlements on a loadable test bundle.
        privileges = entitlements(info.get("CFBundleIdentifier")) if path.suffix in (".app", ".appex") else {}
        if privileges and "TermLLMKeychainAccessGroup" in info:
            # Build output ONLY, never source/project/plist mutation. Keep shared
            # native keychain queries inside the isolated simulator namespace.
            info["TermLLMKeychainAccessGroup"] = SHARED_GROUP
            info_path.write_bytes(plistlib.dumps(info))
        entitlement_file = private / f"simulator-sign-{index}.plist"
        entitlement_file.write_bytes(plistlib.dumps(privileges))
        subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", "--generate-entitlement-der",
                        "--entitlements", str(entitlement_file), str(path)], check=True, capture_output=True)
        subprocess.run(["codesign", "--verify", "--strict", str(path)], check=True, capture_output=True)
        result = subprocess.run(["codesign", "--display", "--entitlements", ":-", str(path)], check=True, capture_output=True)
        actual = plistlib.loads(result.stdout) if result.stdout.strip() else {}
        record = dict(path=str(path.relative_to(products)), entitlements=actual,
                      requested_entitlements=privileges, signature="ad-hoc", verified=True)
        records.append(record)
        provenance["products"] = records
        require(actual == privileges, "Actual ad-hoc signature entitlements differ from simulator policy: " + record["path"])
        if path.name == "TermLLM.app":
            binary = path / info["CFBundleExecutable"]
            linked = embedded_entitlements(binary.read_bytes())
            for item in linked:
                require(item.get("application-identifier") == privileges["application-identifier"], "Linked simulator application identifier mismatch")
                require(item.get("keychain-access-groups") == privileges["keychain-access-groups"], "Linked simulator keychain groups mismatch")
            record.update(linked_entitlements=linked, binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest())
        provenance["products"] = list(records)
    require(any(item["path"] == "TermLLM.app" for item in records), "Main simulator app was not signed")
    for path in bundles:
        if path.suffix == ".app":
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(path)], check=True, capture_output=True)
    provenance.update(namespace=PREFIX, shared_keychain_group=SHARED_GROUP,
                      apple_identity=False, provisioning_profile=False, osstatus_measured=False, products=records)
