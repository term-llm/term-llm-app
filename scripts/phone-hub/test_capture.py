import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('phone_capture_gates', Path(__file__).with_name('verify_capture.py'))
gates = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gates)


class PhoneCaptureGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        summary = dict(result='Passed', passedTests=len(gates.UNITS), failedTests=0, skippedTests=0,
                       devicesAndConfigurations=[dict(device=dict(deviceId='test-device'))])
        self.write('unit-test-summary.json', summary)
        self.write('test-summary.json', dict(summary, passedTests=2))
        self.write('unit-test-tree.json', dict(testNodes=[self.suite(name, ['testExecuted']) for name in gates.UNITS]))
        self.write('test-tree.json', dict(testNodes=[self.suite('PhoneHubUITests', gates.TESTS)]))
        self.requests = [dict(path=path, status=200) for path in sorted(gates.ROUTES - {'/slow/api/nodes'})]
        self.requests.extend([dict(path='/slow/api/nodes', status='stalled'),
                              dict(path='/__control/home/pending-check', status=200),
                              dict(path='/home/api/nodes', status=200),
                              dict(path='/__control/slow/pending-asserted', status=200),
                              dict(path='/work/api/nodes', status=401),
                              dict(path='/home/api/nodes', status=200)])
        self.log()
        (self.root / 'screenshots').mkdir()
        for i in range(10):
            (self.root / 'screenshots' / (str(i) + '.png')).write_bytes(b'\x89PNG\r\n\x1a\nfixture-test-only')
        def box(kind, body):
            return (len(body) + 8).to_bytes(4, 'big') + kind + body
        (self.root / 'phone-hub-demo-fixture.mp4').write_bytes(box(b'ftyp', b'isom') + box(b'mdat', b'\0' * 10000) + box(b'moov', b'unit-test-only'))

    def tearDown(self):
        self.temp.cleanup()

    def suite(self, name, cases):
        return dict(name=name, nodeType='Test Suite', result='Passed',
                    children=[dict(name=case, nodeType='Test Case', result='Passed') for case in cases])

    def write(self, name, value):
        (self.root / name).write_text(json.dumps(value))

    def log(self):
        (self.root / 'fixture-requests.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in self.requests))

    def test_all_four_direct_node_classes_are_executed_and_required(self):
        expected = {'DirectNodeClientTests', 'DirectNodeClientModelTests',
                    'DirectNodeClientMountTests', 'DirectNodeClientCookieFilterTests'}
        command = Path(__file__).with_name('capture.sh').read_text()
        selected = command.split("NATIVE_HUB_UNIT_SUITES='")[1].split("'")[0].split()
        self.assertTrue(expected.issubset(selected))
        self.assertEqual(set(selected), set(gates.UNITS))
        for missing in expected:
            with self.subTest(missing=missing):
                self.write('unit-test-tree.json', dict(testNodes=[
                    self.suite(name, ['testExecuted']) for name in gates.UNITS if name != missing]))
                with self.assertRaisesRegex(ValueError, 'absent or not executed'):
                    gates.verify(self.root, 'test-device')

    def test_completed_slow_before_healthy_progress_is_not_concurrency(self):
        index = next(i for i, row in enumerate(self.requests) if row['status'] == 'stalled')
        self.requests.insert(index + 1, dict(path='/slow/api/nodes', status=504))
        self.log()
        with self.assertRaisesRegex(ValueError, 'while stalled request remained pending'):
            gates.verify(self.root, 'test-device')

    def test_slow_completed_after_healthy_but_before_native_assertion_fails(self):
        index = next(i for i, row in enumerate(self.requests) if row['path'].endswith('/pending-asserted'))
        self.requests.insert(index, dict(path='/slow/api/nodes', status=504))
        self.log()
        with self.assertRaisesRegex(ValueError, 'native slow-request pending assertion'):
            gates.verify(self.root, 'test-device')

    def test_server_wait_without_native_pending_assertion_is_insufficient(self):
        self.requests = [row for row in self.requests if not row['path'].endswith('/pending-asserted')]
        self.log()
        with self.assertRaisesRegex(ValueError, 'native slow-request pending assertion'):
            gates.verify(self.root, 'test-device')

    def test_healthy_response_before_uncached_title_is_armed_is_insufficient(self):
        self.requests = [row for row in self.requests if not row['path'].endswith('/pending-check')]
        self.log()
        with self.assertRaisesRegex(ValueError, 'native slow-request pending assertion'):
            gates.verify(self.root, 'test-device')

    def test_complete_evidence_passes_reused_gates(self):
        gates.verify(self.root, 'TEST-DEVICE')

    def test_missing_direct_source_network_coverage_fails(self):
        self.requests = [row for row in self.requests if row['path'] != '/direct/v1/sessions/status']
        self.log()
        with self.assertRaisesRegex(ValueError, 'coverage'):
            gates.verify(self.root, 'test-device')

    def test_cached_healthy_source_without_post_401_refresh_is_insufficient(self):
        self.requests.pop()
        self.log()
        with self.assertRaisesRegex(ValueError, 'after another source was unauthorized'):
            gates.verify(self.root, 'test-device')

    def test_no_actual_source_401_fails(self):
        self.requests = [row for row in self.requests if row['status'] != 401]
        self.log()
        with self.assertRaisesRegex(ValueError, '401'):
            gates.verify(self.root, 'test-device')

    def test_a_missing_journey_cannot_be_hidden_by_summary_count(self):
        self.write('test-tree.json', dict(testNodes=[self.suite('PhoneHubUITests', gates.TESTS[:1])]))
        with self.assertRaisesRegex(ValueError, 'journey'):
            gates.verify(self.root, 'test-device')

    def test_unregistered_source_unit_suite_is_not_success(self):
        self.write('unit-test-tree.json', dict(testNodes=[self.suite(gates.UNITS[0], ['testExecuted'])]))
        with self.assertRaisesRegex(ValueError, 'absent or not executed'):
            gates.verify(self.root, 'test-device')


if __name__ == '__main__':
    unittest.main()
