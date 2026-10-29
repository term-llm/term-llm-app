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

    def request(self, path, body=None, headers=None, method=None):
        request = urllib.request.Request(self.root + path,
            data=(body if isinstance(body, bytes) else json.dumps(body).encode()) if body is not None else None,
            headers=headers or {}, method=method)
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

    def test_offline_control_changes_node_reachability_not_hub_health(self):
        self.assertEqual(self.request('/__control/work/offline', {})[0], 200)
        _, data = self.request('/work/api/nodes')
        self.assertFalse(data['nodes'][0]['status']['reachable'])
        self.assertEqual(data['nodes'][0]['status']['state'], 'offline')
        self.assertEqual(self.request('/work/healthz')[1]['role'], 'hub')
        self.assertEqual(self.request('/__control/work/healthy', {})[0], 200)
        self.assertTrue(self.request('/work/api/nodes')[1]['nodes'][0]['status']['reachable'])

    def test_hub_new_chat_routes_serve_fixture_html(self):
        for source in ('work', 'home'):
            with urllib.request.urlopen(self.root + '/' + source + '/node/shared/', timeout=3) as response:
                self.assertEqual(response.status, 200)
                self.assertIn((fixture.TITLES[source] + ' fixture chat').encode(), response.read())

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

    def sessions_path(self, source='home'):
        return '/' + source + ('' if source == 'direct' else '/node/shared') + '/v1/sessions'

    def patch_session(self, identifier, body, source='home'):
        return self.request(self.sessions_path(source) + '/' + identifier, body,
                            headers={'Content-Type': 'application/json'}, method='PATCH')

    def test_session_corpus_order_and_wire_shape(self):
        code, data = self.request(self.sessions_path())
        self.assertEqual(code, 200)
        self.assertIsNone(data['selected_session'])
        rows = data['sessions']
        self.assertEqual(len(rows), 75)
        self.assertEqual([(row['id'], row['number'], row['short_title'], row['pin_order']) for row in rows[:3]], [
            ('session-10', 10, 'Benchmark SQLite FTS rebuild', 1),
            ('session-3', 3, 'Kyoto day plan', 2),
            ('session-25', 25, 'Build a reading list', 3)])
        self.assertEqual([(row['id'], row['short_title']) for row in rows[3:8]], [
            ('active-shared', 'Home needs input'), ('session-shared', 'Home result'),
            ('session-4', 'Fix flaky WebRTC reconnect test'),
            ('session-5', 'Plan the autumn vegetable garden'), ('session-6', 'Review accessibility labels')])
        self.assertEqual(rows[3:], sorted(rows[3:], key=lambda row: (-row['last_message_at'], -row['number'])))
        self.assertEqual(len({row['short_title'] for row in rows}), 75)
        self.assertEqual(sum(row['attention_unseen'] for row in rows), 3)
        self.assertEqual(rows[4]['attention_seq'], 1)
        self.assertTrue(any('project_name' in row for row in rows))
        self.assertNotIn('project_name', rows[3])
        self.assertEqual(min(row['last_message_at'] for row in rows), 1792735200000 - 146 * 86_400_000)
        for row in rows:
            self.assertEqual(row['attention_store_instance_id'], 'store-home')
            self.assertFalse(row['archived'])
            self.assertEqual(row['seen_rev'], 0)
            self.assertLessEqual(row['created_at'], row['last_message_at'])
            self.assertTrue(2 <= row['message_count'] <= 120)
            self.assertEqual('pin_order' in row, row['pinned'])
            self.assertNotIn('_original_title', row)
            self.assertNotIn('name', row)
        for source, count, pins in (('work', 5, 1), ('slow', 5, 1), ('direct', 2, 0)):
            code, data = self.request(self.sessions_path(source))
            self.assertEqual(code, 200)  # Slow node APIs must not stall.
            self.assertEqual(len(data['sessions']), count)
            self.assertEqual(sum(row['pinned'] for row in data['sessions']), pins)
            if source in ('work', 'slow'):
                self.assertTrue(all(row['short_title'].startswith(fixture.TITLES[source]) for row in data['sessions']))

    def test_session_paging_and_legacy_snapshot(self):
        path = self.sessions_path()
        _, snapshot = self.request(path)
        self.assertNotIn('next_cursor', snapshot)
        pages = []
        query = '?scope=all&limit=30'
        for expected_size in (30, 30, 15):
            code, page = self.request(path + query)
            self.assertEqual(code, 200)
            self.assertEqual(len(page['sessions']), expected_size)
            pages.extend(page['sessions'])
            if expected_size == 15:
                self.assertNotIn('next_cursor', page)
            else:
                query = '?limit=30&cursor=' + page['next_cursor']
        self.assertEqual(pages, snapshot['sessions'])
        self.assertEqual(len({row['id'] for row in pages}), 75)
        for limit in ('0', '-1', 'oops', '1.5', '', '1_0', '%2030'):
            with self.subTest(limit=limit):
                self.assertEqual(len(self.request(path + '?limit=' + limit)[1]['sessions']), 12)
        self.assertEqual(len(self.request(path + '?limit=1000')[1]['sessions']), 75)
        cursor = self.request(path + '?limit=30')[1]['next_cursor']
        self.assertEqual(len(self.request(path + '?cursor=' + cursor)[1]['sessions']), 12)
        # A larger synthetic state verifies the legacy snapshot and limit cap independently.
        with self.server.state_lock:
            for number in range(76, 111):
                row = dict(self.server.sessions['home']['session-75'], id='session-' + str(number), number=number)
                self.server.sessions['home'][row['id']] = row
        _, snapshot = self.request(path)
        self.assertEqual(len(snapshot['sessions']), 100)
        self.assertNotIn('next_cursor', snapshot)
        _, limited = self.request(path + '?limit=1000')
        self.assertEqual(len(limited['sessions']), 100)
        self.assertIn('next_cursor', limited)

    def test_session_scope_and_cursor_validation(self):
        path = self.sessions_path()
        for scope in ('project', ''):
            self.assertEqual(self.request(path + '?scope=' + scope), (400, {
                'error': {'type': 'invalid_request_error', 'message': 'unsupported session scope'}}))
        foreign = self.request(self.sessions_path('work') + '?limit=2')[1]['next_cursor']
        for cursor in ('not-a-cursor', '', 'W10', foreign,
                       fixture.session_cursor('home', -1), fixture.session_cursor('home', True)):
            with self.subTest(cursor=cursor):
                self.assertEqual(self.request(path + '?cursor=' + cursor), (400, {
                    'error': {'type': 'invalid_cursor',
                              'message': 'session cursor does not belong to this session listing'}}))

    def test_session_pin_unpin_rename_archive_and_source_isolation(self):
        code, pin = self.patch_session('session-4', {'pinned': True})
        self.assertEqual(code, 200)
        self.assertEqual(pin, dict(id='session-4', name='', short_title='Fix flaky WebRTC reconnect test',
                                  long_title='', generated_short_title='', generated_long_title='',
                                  mode='chat', origin='web', archived=False, pinned=True, pin_order=4,
                                  created_at=1792735200000 - 5 * 86_400_000))
        self.assertEqual(self.patch_session('session-4', {'pinned': True})[1]['pin_order'], 4)
        self.assertEqual([row['pin_order'] for row in self.request(self.sessions_path())[1]['sessions'][:4]], [1, 2, 3, 4])
        code, renamed = self.patch_session('session-4', {'name': '  Reconnect investigation  '})
        self.assertEqual(code, 200)
        self.assertEqual(renamed['name'], 'Reconnect investigation')
        self.assertEqual(renamed['short_title'], 'Reconnect investigation')
        self.assertEqual(self.request(self.sessions_path())[1]['sessions'][3]['short_title'], renamed['name'])
        self.assertEqual(self.patch_session('session-4', {'name': '  '})[1]['short_title'], pin['short_title'])
        code, unpin = self.patch_session('session-4', {'pinned': False})
        self.assertEqual(code, 200)
        self.assertFalse(unpin['pinned'])
        self.assertEqual(unpin['pin_order'], 0)
        self.patch_session('session-3', {'pinned': False})
        pins = [row['pin_order'] for row in self.request(self.sessions_path())[1]['sessions'] if row['pinned']]
        self.assertEqual(pins, [1, 3])
        self.assertEqual(self.patch_session('session-4', {'pinned': True})[1]['pin_order'], 4)
        self.assertEqual(self.patch_session('session-4', {'archived': True})[0], 200)
        rows = self.request(self.sessions_path())[1]['sessions']
        self.assertEqual(len(rows), 74)
        self.assertNotIn('session-4', [row['id'] for row in rows])
        self.assertEqual(self.patch_session('session-4', {'archived': False})[0], 200)
        self.assertEqual(len(self.request(self.sessions_path())[1]['sessions']), 75)
        work = self.request(self.sessions_path('work'))[1]['sessions']
        self.assertEqual(len(work), 5)
        self.assertEqual(next(row for row in work if row['id'] == 'session-4')['short_title'],
                         'Work Fix flaky WebRTC reconnect test')
        self.assertEqual(self.patch_session('session-shared', {'name': 'Laptop renamed'}, 'direct')[0], 200)
        self.assertEqual(self.request(self.sessions_path('direct'))[1]['sessions'][1]['short_title'], 'Laptop renamed')

    def test_pinned_order_moves_subset_within_existing_ranks(self):
        code, data = self.patch_session('pinned-order', {'session_ids': ['session-25', 'session-10']})
        self.assertEqual(code, 200)
        self.assertEqual(data, {'pinned': [dict(id='session-25', pin_order=1),
                                           dict(id='session-3', pin_order=2), dict(id='session-10', pin_order=3)]})
        self.assertEqual([row['id'] for row in self.request(self.sessions_path())[1]['sessions'][:3]],
                         ['session-25', 'session-3', 'session-10'])
        self.assertEqual(self.patch_session('pinned-order', {'session_ids': []}), (200, data))
        self.assertEqual(self.patch_session('pinned-order', {'session_ids': ['session-4']}), (409, {
            'error': {'type': 'conflict_error',
                      'message': 'a listed session is no longer pinned; refresh and try again'}}))
        self.assertEqual(self.patch_session('pinned-order', {'session_ids': ['missing']}), (404, {
            'error': {'type': 'not_found_error', 'message': 'session not found'}}))
        self.assertEqual(self.request(self.sessions_path())[1]['sessions'][0]['id'], 'session-25')

    def test_session_patch_input_validation(self):
        for body in ({'name': 1}, {'name': None}, {'archived': 1}, {'archived': 'true'},
                     {'pinned': 0}, {'pinned': None}, [], 'text'):
            with self.subTest(body=body):
                self.assertEqual(self.patch_session('session-4', body)[0], 400)
        for body in ({}, {'session_ids': 'session-10'}, {'session_ids': [1]},
                     {'session_ids': ['session-10', 'session-10']}, {'session_ids': [{}]}):
            with self.subTest(body=body):
                self.assertEqual(self.patch_session('pinned-order', body)[0], 400)
        path = self.sessions_path() + '/session-4'
        self.assertEqual(self.request(path, {}, method='PATCH')[0], 400)
        self.assertEqual(self.request(path, b'{bad', {'Content-Type': 'application/json'}, 'PATCH')[0], 400)
        self.assertEqual(self.request(path, {'name': 'x' * (16 * 1024)},
                                      {'Content-Type': 'application/json'}, 'PATCH')[0], 413)
        self.assertEqual(self.request(path, b'{}' + b' ' * (16 * 1024 - 2),
                                      {'Content-Type': 'application/json; charset=utf-8'}, 'PATCH')[0], 200)
        self.assertEqual(self.request(path, {}, {'Content-Type': 'text/plain'}, 'PATCH')[0], 400)
        self.assertEqual(self.patch_session('missing', {'name': 'test'}), (404, {
            'error': {'type': 'not_found_error', 'message': 'session not found'}}))
        self.assertEqual(self.patch_session('session-4', {'pinned': True, 'name': 1})[0], 400)
        self.assertFalse(next(row for row in self.request(self.sessions_path())[1]['sessions']
                              if row['id'] == 'session-4')['pinned'])

    def test_session_routes_unauthorized_for_hub_and_direct(self):
        expected = (401, {'error': {'type': 'invalid_session', 'message': 'Synthetic source sign-in required'}})
        for source in ('work', 'home', 'slow', 'direct'):
            self.request('/__control/' + source + '/unauthorized', {})
            self.assertEqual(self.request(self.sessions_path(source)), expected)
            self.assertEqual(self.patch_session('session-shared', {'name': 'denied'}, source), expected)
            self.assertEqual(self.patch_session('pinned-order', {'session_ids': []}, source), expected)
            self.request('/__control/' + source + '/healthy', {})
            rows = self.request(self.sessions_path(source))[1]['sessions']
            self.assertEqual(next(row for row in rows if row['id'] == 'session-shared')['short_title'],
                             fixture.TITLES[source] + ' result')

    def test_sessions_page_error_is_one_shot_and_source_scoped(self):
        path = self.sessions_path()
        cursor = self.request(path + '?limit=30')[1]['next_cursor']
        self.assertEqual(self.request('/__control/home/sessions-page-error', {}),
                         (200, {'fixture': True, 'state': 'sessions-page-error'}))
        self.assertEqual(self.request(path + '?limit=30')[0], 200)
        work_cursor = self.request(self.sessions_path('work') + '?limit=2')[1]['next_cursor']
        self.assertEqual(self.request(self.sessions_path('work') + '?cursor=' + work_cursor)[0], 200)
        next_page = path + '?limit=30&cursor=' + cursor
        self.assertEqual(self.request(next_page), (503, {
            'error': {'type': 'fixture_unavailable', 'message': 'Synthetic page failure'}}))
        code, page = self.request(next_page)
        self.assertEqual(code, 200)
        self.assertEqual(len(page['sessions']), 30)
        self.assertEqual(self.request(next_page), (200, page))

    def test_healthy_control_restores_the_session_corpus(self):
        self.assertEqual(self.patch_session('session-4', {'pinned': True})[0], 200)
        self.assertEqual(self.patch_session('session-5', {'archived': True})[0], 200)
        self.assertEqual(self.request('/__control/home/sessions-page-error', {})[0], 200)
        self.assertEqual(self.request('/__control/home/healthy', {}), (200, {'fixture': True, 'state': 'healthy'}))
        rows = self.request(self.sessions_path())[1]['sessions']
        self.assertEqual([row['id'] for row in rows if row['pinned']], ['session-10', 'session-3', 'session-25'])
        self.assertIn('session-5', [row['id'] for row in rows])
        cursor = self.request(self.sessions_path() + '?limit=30')[1]['next_cursor']
        self.assertEqual(self.request(self.sessions_path() + '?limit=30&cursor=' + cursor)[0], 200,
                         'a pending page failure is cleared too')

    def test_corpus_status_preserves_search_and_tracks_mutations(self):
        for source in ('home', 'work', 'slow', 'direct'):
            path = self.sessions_path(source)
            ids = 'active-shared,session-shared,search-11,missing'
            if source != 'direct':
                self.patch_session('session-4', {'name': 'Renamed status'}, source)
                ids += ',session-4'
            code, data = self.request(path + '/status?ids=' + ids)
            self.assertEqual(code, 200)
            self.assertEqual([row['id'] for row in data['sessions'][:3]], ['active-shared', 'session-shared', 'search-11'])
            for row in data['sessions']:
                self.assertEqual(row['active_run'], row['id'] == 'active-shared' or
                                 (source == 'work' and row['id'] == 'search-11'))
                self.assertEqual(row['interaction_required'], row['id'] == 'active-shared')
            if source != 'direct':
                self.assertEqual(data['sessions'][-1]['short_title'], 'Renamed status')
            self.assertEqual(self.request(path + '/search?q=relay')[1], fixture.search_sessions(source, 'relay'))

    def test_dashboard_outputs_are_unchanged_by_session_mutations(self):
        paths = ['/work/api/nodes', '/home/api/nodes', '/direct/v1/sessions/status',
                 '/work/node/shared/v1/sessions/status', '/home/node/shared/v1/sessions/status']
        before = {path: self.request(path) for path in paths}
        self.assertEqual(before['/home/api/nodes'], (200, {'nodes': [fixture.hub_node('home')]}))
        self.assertEqual(before['/direct/v1/sessions/status'], (200, {
            'sessions': [fixture.session('direct', True), fixture.session('direct')]}))
        self.assertEqual(before['/home/node/shared/v1/sessions/status'], (200, {'sessions': []}))
        for source in ('work', 'home', 'direct'):
            self.patch_session('session-shared', {'name': 'Changed', 'archived': True, 'pinned': True}, source)
        for path in paths:
            self.assertEqual(self.request(path), before[path])

    def test_session_requests_keep_logs_private(self):
        self.request(self.sessions_path() + '?limit=1&secret=not-public',
                     headers={'Authorization': 'Bearer not-public', 'Cookie': 'not-public'})
        self.patch_session('session-4', {'name': 'not-public'})
        self.request('/__control/home/sessions-page-error', {'secret': 'not-public'})
        self.request(self.sessions_path() + '?cursor=not-public')
        text = self.log.read_text()
        self.assertNotIn('not-public', text)
        self.assertNotIn('?', text)
        for line in text.splitlines():
            self.assertEqual(set(json.loads(line)), {'time', 'method', 'path', 'status'})

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
