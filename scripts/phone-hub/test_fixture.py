import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

SPEC = importlib.util.spec_from_file_location('phone_fixture', Path(__file__).with_name('fixture_server.py'))
fixture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixture)


class PhoneFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.log = Path(self.temp.name) / 'requests.jsonl'
        self.server = fixture.PhoneFixtureServer(('127.0.0.1', 0), self.log)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.root = 'http://127.0.0.1:' + str(self.server.server_port)

    def tearDown(self):
        self.server.stopping.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(5)
        self.temp.cleanup()

    def request(self, path, body=None, headers=None):
        request = urllib.request.Request(self.root + path,
            data=json.dumps(body).encode() if body is not None else None,
            headers=headers or {})
        try:
            response = urllib.request.urlopen(request, timeout=3)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            data = response.read()
            return response.status, json.loads(data) if data else None

    def test_mounted_hubs_keep_private_node_addresses_display_only(self):
        for source in ('work', 'home'):
            status, data = self.request('/' + source + '/api/nodes')
            self.assertEqual(status, 200)
            node = data['nodes'][0]
            self.assertEqual(node['url'], 'https://private-node.invalid/')
            self.assertEqual(node['id'], 'shared')
            self.assertEqual(node['proxy_path'], '/' + source + '/node/shared/')
            self.assertTrue(node['sessions']['recent'][0]['resume_path'].startswith('/' + source + '/'))

    def test_duplicate_remote_identifiers_have_distinct_source_markers(self):
        _, work = self.request('/work/api/attention')
        _, home = self.request('/home/api/attention')
        _, direct = self.request('/direct/v1/attention?kind=unseen&limit=20')
        self.assertEqual(work['inbox'][0]['session_id'], home['inbox'][0]['session_id'])
        self.assertEqual(home['inbox'][0]['session_id'], direct['items'][0]['session_id'])
        self.assertEqual(work['inbox'][0]['attention_seq'], direct['items'][0]['attention_seq'])
        self.assertEqual(len({work['inbox'][0]['store_instance_id'], home['inbox'][0]['store_instance_id'], direct['store_instance_id']}), 3)

    def test_direct_node_status_and_attention_are_real_api_shapes(self):
        self.assertEqual(self.request('/direct/api/auth/session')[0], 404)
        _, status = self.request('/direct/v1/sessions/status')
        self.assertEqual(len(status['sessions']), 2)
        self.assertTrue(status['sessions'][0]['active_run'])
        for kind in ('running', 'input_required', 'unseen'):
            code, page = self.request('/direct/v1/attention?kind=' + kind + '&limit=200')
            self.assertEqual(code, 200)
            self.assertEqual(page['protocol_version'], 2 if kind == 'input_required' else 1)
            self.assertEqual(page['store_instance_id'], 'store-direct')
            self.assertIn('seen_rev', page['items'][0])
        self.assertEqual(self.request('/direct/v1/attention')[0], 400)
        self.assertEqual(self.request('/direct/v1/attention?kind=unseen&limit=501')[0], 400)

    def test_seen_changes_exactly_one_source(self):
        self.assertEqual(self.request('/work/api/attention/seen',
            dict(store_instance_id='store-work', session_id='session-shared', attention_seq=1))[0], 200)
        self.assertEqual(self.request('/work/api/attention')[1]['inbox'], [])
        self.assertEqual(len(self.request('/home/api/attention')[1]['inbox']), 1)
        self.assertEqual(len(self.request('/direct/v1/attention?kind=unseen')[1]['items']), 1)

    def test_direct_seen_uses_through_seq_not_hub_payload(self):
        path = '/direct/v1/sessions/session-shared/attention/seen'
        self.assertEqual(self.request(path, dict(store_instance_id='store-direct', attention_seq=1))[0], 409)
        self.assertEqual(self.request(path, dict(store_instance_id='store-direct', through_seq=1))[0], 200)
        self.assertEqual(self.request('/direct/v1/attention?kind=unseen')[1]['items'], [])

    def test_source_unauthorized_does_not_change_other_sources(self):
        self.assertEqual(self.request('/__control/work/unauthorized', {})[0], 200)
        self.assertEqual(self.request('/work/api/nodes')[0], 401)
        self.assertEqual(self.request('/work/api/attention/seen', {})[0], 401)
        self.assertEqual(self.request('/home/api/nodes')[0], 200)
        self.assertEqual(self.request('/direct/v1/sessions/status')[0], 200)
        self.assertEqual(self.request('/work/healthz')[0], 200)

    def test_healthy_source_responds_while_slow_request_is_pending(self):
        with ThreadPoolExecutor(max_workers=1) as pool:
            pending = pool.submit(self.request, '/slow/api/nodes')
            for _ in range(100):
                if self.log.exists() and 'stalled' in self.log.read_text():
                    break
                threading.Event().wait(0.01)
            self.assertIn('stalled', self.log.read_text())
            self.assertEqual(self.request('/home/api/nodes')[0], 200)
            self.assertEqual(self.request('/direct/v1/sessions/status')[0], 200)
            self.assertFalse(pending.done())
            self.server.stopping.set()
            # The owned pending socket closes without a fabricated successful response.
            try:
                pending.result(timeout=3)
            except Exception:
                pass

    def test_pending_ack_requires_real_slow_and_fresh_healthy_response(self):
        self.assertEqual(self.request('/__control/slow/pending-asserted', {})[0], 409)
        self.assertEqual(self.request('/__control/home/pending-check', {})[0], 200)
        self.assertEqual(self.request('/home/api/nodes')[1]['nodes'][0]['name'], 'Home pending-check refresh')
        # Healthy progress on its own must not claim a pending native request.
        self.assertEqual(self.request('/__control/slow/pending-asserted', {})[0], 409)
        with ThreadPoolExecutor(max_workers=1) as pool:
            pending = pool.submit(self.request, '/slow/api/nodes')
            for _ in range(100):
                with self.server.state_lock:
                    started = self.server.slow_nodes_pending > 0
                if started:
                    break
                threading.Event().wait(0.01)
            self.assertTrue(started)
            self.request('/__control/home/pending-check', {})
            self.assertEqual(self.request('/__control/slow/pending-asserted', {})[0], 409)
            self.request('/home/api/nodes')
            self.assertFalse(pending.done())
            self.assertEqual(self.request('/__control/slow/pending-asserted', {})[0], 200)
            self.server.stopping.set()
            try:
                pending.result(timeout=3)
            except Exception:
                pass

    def test_request_log_contains_no_credentials_query_or_body(self):
        self.request('/work/api/nodes?secret=not-public', headers={'Authorization': 'Bearer not-public', 'Cookie': 'not-public'})
        self.request('/__control/work/healthy', {'secret': 'not-public'})
        text = self.log.read_text()
        self.assertNotIn('not-public', text)
        self.assertNotIn('?', text)
        for line in text.splitlines():
            self.assertEqual(set(json.loads(line)), {'time', 'method', 'path', 'status'})


if __name__ == '__main__':
    unittest.main()
