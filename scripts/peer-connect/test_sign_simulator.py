"""Synthetic Mach-O/mock codesign unit tests only; not actual signing evidence."""
import plistlib
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from contract import ContractError
from sign_simulator import SHARED_GROUP, build_entitlements, embedded_entitlements, entitlements, sign_products


def macho(privileges):
    payload = plistlib.dumps(privileges)
    header = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 1, 152, 0, 0)
    segment = struct.pack('<II16sQQQQIIII', 0x19, 152, b'__TEXT', 0, 0, 0, 0, 7, 5, 1, 0)
    section = struct.pack('<16s16sQQIIIIIIII', b'__entitlements', b'__TEXT', 0, len(payload), 184, 0, 0, 0, 0, 0, 0, 0)
    return header + segment + section + payload


class SigningPolicyTests(unittest.TestCase):
    def test_generated_build_entitlements_expand_per_actual_target(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'capture.entitlements'
            build_entitlements(path)
            value = plistlib.loads(path.read_bytes())
            self.assertEqual(value['application-identifier'], 'SIMULATOR.$(PRODUCT_BUNDLE_IDENTIFIER)')
            self.assertEqual(value['keychain-access-groups'][1], SHARED_GROUP)
            self.assertNotIn('aps-environment', value)
            self.assertNotIn('com.apple.security.application-groups', value)

    def test_executable_bundle_namespaces_are_distinct(self):
        for identifier in ('com.termllm.app', 'com.termllm.app.NotificationService'):
            value = entitlements(identifier)
            self.assertEqual(value['keychain-access-groups'][0], 'SIMULATOR.' + identifier)
            self.assertEqual(value['application-identifier'], 'SIMULATOR.' + identifier)
        with self.assertRaises(ContractError):
            entitlements('com.apple.unrelated')

    def test_actual_macho_section_is_required_and_decoded(self):
        expected = entitlements('com.termllm.app')
        self.assertEqual(embedded_entitlements(macho(expected)), [expected])
        missing = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 0, 0, 0, 0)
        with self.assertRaisesRegex(ContractError, 'lacks linked'):
            embedded_entitlements(missing)

    def test_every_universal_slice_is_checked(self):
        image = macho(entitlements('com.termllm.app'))
        offset = 8 + 2 * 20
        fat = struct.pack('>II', 0xcafebabe, 2)
        fat += struct.pack('>5I', 0x100000c, 0, offset, len(image), 0)
        fat += struct.pack('>5I', 0x1000007, 0, offset + len(image), len(image), 0)
        self.assertEqual(len(embedded_entitlements(fat + image + image)), 2)

    def test_all_xcode_signatures_and_plists_preserved_readonly(self):
        with tempfile.TemporaryDirectory() as temp:
            # Exercise canonical path handling (/var vs /private/var on macOS).
            actual = Path(temp) / 'actual'
            actual.mkdir()
            root = Path(temp) / 'alias'
            root.symlink_to(actual, target_is_directory=True)
            products, private = root / 'Products', root / 'private'
            products.mkdir()
            private.mkdir()
            app = products / 'TermLLM.app'
            extension = app / 'PlugIns/Notification.appex'
            framework = app / 'Frameworks/WebRTC.framework'
            test_bundle = app / 'PlugIns/TermLLMTests.xctest'
            runner = products / 'TermLLMUITests-Runner.app'
            apple_framework = runner / 'Frameworks/XCTest.framework'
            library = runner / 'Frameworks/libXCTestBundleInject.dylib'
            fixtures = ((app, 'com.termllm.app'), (extension, 'com.termllm.app.NotificationService'),
                        (framework, 'org.webrtc'), (test_bundle, 'com.termllm.app.tests'),
                        (runner, 'com.termllm.app.uitests.xctrunner'), (apple_framework, 'com.apple.dt.XCTest'))
            for path, identifier in fixtures:
                path.mkdir(parents=True, exist_ok=True)
                (path / 'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier=identifier,
                    CFBundleExecutable='Executable', TermLLMKeychainAccessGroup='unexpanded.shared')))
                (path / 'Executable').write_bytes(macho(entitlements(identifier)) if path == app else b'test-placeholder')
            library.write_bytes(b'test-library-placeholder')
            paths = [p.resolve() for p, _ in fixtures] + [library.resolve()]
            signatures = {str(p): {'stock-xcode-test-marker': True} for p in paths}
            signatures[str(app.resolve())] = {}  # Normal Xcode physical .xcent.
            stock = {str(p): dict(signatures[str(p)]) for p in paths}
            infos = {p: (p / 'Info.plist').read_bytes() for p, _ in fixtures}
            runner_info = (runner / 'Info.plist').read_bytes()
            def command(args, **kwargs):
                path = args[-1]
                self.assertNotIn('--sign', args)
                self.assertNotIn('--force', args)
                if '--verify' in args:
                    if Path(path).suffix in ('.framework', '.dylib'):
                        self.assertIn('--ignore-resources', args)
                    else:
                        self.assertNotIn('--ignore-resources', args)
                output = plistlib.dumps(signatures[path]) if '--entitlements' in args and '--display' in args else b''
                details = str(signatures[path]).encode() if '--verbose=4' in args else b''
                return subprocess.CompletedProcess(args, 0, stdout=output, stderr=details)
            provenance = {}
            with patch('sign_simulator.subprocess.run', side_effect=command):
                sign_products(products, private, provenance)
            for path, signature in stock.items():
                self.assertEqual(signatures[path], signature)
            self.assertEqual((runner / 'Info.plist').read_bytes(), runner_info)
            for path, original in infos.items():
                self.assertEqual((path / 'Info.plist').read_bytes(), original)
            self.assertEqual(plistlib.loads((app / 'Info.plist').read_bytes())['TermLLMKeychainAccessGroup'], 'unexpanded.shared')
            self.assertFalse(provenance['osstatus_measured'])
            self.assertEqual(len(provenance['products']), 7)
            runner_record = next(r for r in provenance['products'] if r['path'] == 'TermLLMUITests-Runner.app')
            self.assertEqual(runner_record['action'], 'preserved-xcode-code')
            self.assertTrue(runner_record['resource_envelope_validated'])
            self.assertIn('resource ignore ONLY', provenance['preserved_validation'])
            self.assertEqual(provenance['signing_scope'], 'none-read-only-verification')
            main_record = next(r for r in provenance['products'] if r['path'] == 'TermLLM.app')
            self.assertEqual(main_record['entitlements'], {})
            self.assertTrue(main_record['resource_envelope_validated'])
            self.assertEqual(main_record['linked_entitlements'][0]['application-identifier'], 'SIMULATOR.com.termllm.app')
            self.assertEqual(runner_record['before']['entitlements'], runner_record['entitlements'])
            self.assertEqual(runner_record['before']['signature_details'], runner_record['signature_details'])
            self.assertEqual(runner_record['before']['binary_sha256'], runner_record['binary_sha256'])
            self.assertTrue(next(r for r in provenance['products'] if r['path'] == 'TermLLM.app')['linked_entitlements'])


if __name__ == '__main__':
    unittest.main()
