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
        for identifier in ('com.termllm.app', 'com.termllm.app.NotificationService', 'com.termllm.app.uitests.xctrunner'):
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

    def test_nested_bundles_signed_inside_out_and_shared_queries_isolated(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            products, private = root / 'Products', root / 'private'
            products.mkdir()
            private.mkdir()
            app = products / 'TermLLM.app'
            extension = app / 'PlugIns/Notification.appex'
            framework = app / 'Frameworks/WebRTC.framework'
            for path, identifier in ((app, 'com.termllm.app'), (extension, 'com.termllm.app.NotificationService'), (framework, 'org.webrtc')):
                path.mkdir(parents=True, exist_ok=True)
                (path / 'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier=identifier, CFBundleExecutable='Executable', TermLLMKeychainAccessGroup='unexpanded.shared')))
                (path / 'Executable').write_bytes(macho(entitlements(identifier)) if path == app else b'test-placeholder')
            signatures, order = {}, []
            def command(args, **kwargs):
                path = args[-1]
                if '--sign' in args:
                    order.append(path)
                    self.assertIn('-', args)
                    signatures[path] = plistlib.loads(Path(args[args.index('--entitlements') + 1]).read_bytes())
                output = plistlib.dumps(signatures[path]) if '--display' in args else b''
                return subprocess.CompletedProcess(args, 0, stdout=output, stderr=b'')
            provenance = {}
            with patch('sign_simulator.subprocess.run', side_effect=command):
                sign_products(products, private, provenance)
            self.assertLess(order.index(str(extension)), order.index(str(app)))
            self.assertLess(order.index(str(framework)), order.index(str(app)))
            self.assertEqual(signatures[str(framework)], {})
            self.assertEqual(plistlib.loads((app / 'Info.plist').read_bytes())['TermLLMKeychainAccessGroup'], SHARED_GROUP)
            self.assertFalse(provenance['osstatus_measured'])
            self.assertEqual(len(provenance['products']), 3)
            self.assertTrue(next(record for record in provenance['products'] if record['path'] == 'TermLLM.app')['linked_entitlements'])


if __name__ == '__main__':
    unittest.main()
