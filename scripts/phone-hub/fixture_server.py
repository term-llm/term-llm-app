#!/usr/bin/env python3
"""Loopback-only MULTI-SOURCE PROTOCOL FIXTURE. Not real agents or authentication.

Reuses native-hub fixture HTML/response/logging helpers. Wire fields are from
core 2496b5fd (unchanged through 5147a9f6 for direct attention/session APIs).
Three sources deliberately collide on remote node/session/attention identifiers.
"""
import argparse
import html
from http.server import ThreadingHTTPServer
import importlib.util
import json
from pathlib import Path
import threading
from urllib.parse import parse_qs, urlsplit

BASE = Path(__file__).resolve().parents[1] / 'native-hub' / 'fixture_server.py'
SPEC = importlib.util.spec_from_file_location('native_hub_fixture', BASE)
legacy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(legacy)
CORE_COMMIT = legacy.CORE_COMMIT
LABEL = legacy.LABEL
STAMP = legacy.STAMP
SOURCES = {'work': 'Work Hub', 'home': 'Home Hub', 'direct': 'Laptop', 'slow': 'Slow Hub'}
TITLES = {'work': 'Work', 'home': 'Home', 'direct': 'Laptop', 'slow': 'Slow'}


def session(source, active=False):
    prefix = TITLES[source]
    number = 2 if active else 1
    return dict(id='active-shared' if active else 'session-shared', number=number,
                short_title=prefix + (' needs input' if active else ' result'), long_title='',
                pinned=False, active_run=active, interaction_required=active,
                pending_interaction_count=int(active), pending_interaction_kinds=['approval'] if active else [],
                last_message_at=1792735200000, message_count=4)


def hub_node(source):
    root = '/' + source + '/node/shared/'
    entries = [session(source, True), session(source)]
    for item in entries:
        item['resume_path'] = root + 'chat/' + str(item['number'])
    return dict(id='shared', name=TITLES[source] + ' agent', source='local', connection='reverse',
                # Display-only address: any attempt to dial this is a routing bug.
                url='https://private-node.invalid/', base_path='/private/',
                proxy_path=root, new_session_path=root + '?new=1', has_token=True,
                status=dict(reachable=True, state='ok', latency_ms=12,
                            version='protocol-fixture', agent='fixture', capabilities=['attention']),
                sessions=dict(count_label='2 sessions', active_count=1, input_required_count=1,
                              unseen_count=1, attention_capability='supported', active=[entries[0]],
                              recent=[entries[1]], resume_path=entries[1]['resume_path']), diagnostics=[])


def hub_attention(source, seen=False):
    title = TITLES[source]
    root = '/' + source + '/node/shared/chat/'
    return dict(total_running=1, total_input_required=1, total_unseen=0 if seen else 1,
                nodes=[dict(node_id='shared', node_name=title + ' agent', capability_state='supported',
                            stale=False, last_success_at=STAMP, running_count=1, input_required_count=1,
                            unseen_count=0 if seen else 1, has_green_indicator=not seen)],
                input_required=[dict(node_id='shared', node_name=title + ' agent', session_id='active-shared',
                                     session_number=2, title=title + ' needs input', pending_interaction_count=1,
                                     pending_interaction_kinds=['approval'], required_since=STAMP,
                                     resume_path=root + '2', stale=False)],
                inbox=[] if seen else [dict(node_id='shared', node_name=title + ' agent',
                          store_instance_id='store-' + source, session_id='session-shared', session_number=1,
                          title=title + ' result', outcome='completed', terminal_at=STAMP,
                          attention_seq=1, resume_path=root + '1')], has_more=False)


def node_attention(source, kind, seen=False):
    active = kind in ('running', 'input_required')
    item = dict(seen_through_seq=0, seen_rev=0, session_id='active-shared' if active else 'session-shared',
                session_number=2 if active else 1, response_id='resp-active' if active else 'resp-shared',
                kind=kind, lifecycle_state='running' if active else 'completed', attention_seq=1,
                short_title=TITLES[source] + (' needs input' if active else ' result'),
                outcome='running' if active else 'completed', started_at=STAMP,
                interaction_required=active, pending_interaction_count=int(active),
                pending_interaction_kinds=['approval'] if active else [])
    item['interaction_required_since' if active else 'terminal_at'] = STAMP
    return dict(protocol_version=2 if kind == 'input_required' else 1, store_instance_id='store-' + source, snapshot_version=1,
                items=[] if (seen and not active) else [item], has_more=False)


def search_corpus(source):
    title = TITLES[source]
    return [
        (11, title + ' relay retry backoff', 'tuned the **relay** retry backoff for push delivery'),
        (12, title + ' CI cache cleanup', 'cleared the **cache** key so CI stops reusing stale builds'),
        (13, title + ' release notes draft', 'drafted **release** notes for the next build'),
    ]


def search_sessions(source, query):
    """Synthetic full-text matches beyond the dashboard's recent window."""
    needle = query.strip().lower()
    matches = [row for row in search_corpus(source) if needle and needle in (row[1] + ' ' + row[2].replace('**', '')).lower()]
    return dict(sessions=[dict(id='search-' + str(number), number=number, short_title=short, long_title='',
                               pinned=False, last_message_at=1792735200000 - number * 3_600_000, message_count=6,
                               snippet=snippet, attention_unseen=False) for number, short, snippet in matches])


def status_for_ids(source, raw_ids):
    """`/v1/sessions/status?ids=`: exactly the requested synthetic sessions."""
    wanted = [item for item in raw_ids.split(',') if item]
    rows = {'search-' + str(number): dict(id='search-' + str(number), number=number, short_title=short, long_title='',
                                         active_run=number == 11 and source == 'work', interaction_required=False,
                                         last_message_at=1792735200000 - number * 3_600_000, message_count=6)
            for number, short, _ in search_corpus(source)}
    for item in (session(source, True), session(source)):
        rows[item['id']] = item
    return dict(sessions=[rows[item] for item in wanted if item in rows])


class PhoneFixtureServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, request_log=None, stall_seconds=90):
        self.request_log = Path(request_log) if request_log else None
        self.log_lock = threading.Lock()
        self.state_lock = threading.Lock()
        self.stall_seconds = stall_seconds
        self.stopping = threading.Event()
        self.source_modes = {key: 'healthy' for key in SOURCES}
        self.slow_nodes_pending = 0
        self.pending_check_healthy_completed = False
        self.seen = set()
        super().__init__(address, Handler)

    def server_close(self):
        self.stopping.set()
        super().server_close()


class Handler(legacy.Handler):
    def json(self, status, value):
        self.send(status, json.dumps(value).encode())

    def do_GET(self):
        parts = urlsplit(self.path)
        path = parts.path
        if path == '/__health':
            self.json(200, dict(fixture=True, label=LABEL, core_commit=CORE_COMMIT))
            return
        segments = path.strip('/').split('/')
        source = segments[0]
        if source not in SOURCES:
            self.json(404, dict(error='Unknown fixture route'))
            return
        route = '/' + '/'.join(segments[1:])
        with self.server.state_lock:
            mode = self.server.source_modes[source]
            seen = source in self.server.seen
        if mode == 'delayed-update' and route in ('/api/nodes', '/api/attention', '/api/delegations'):
            self.server.stopping.wait(2)
        if route == '/healthz':
            data = dict(status='ok', version='protocol-fixture', agent='direct-node' if source == 'direct' else TITLES[source], capabilities=['attention'])
            if source != 'direct':
                data['role'] = 'hub'
            self.json(200, data)
        elif mode == 'unauthorized' and (route.startswith('/api/') or route.startswith('/v1/')):
            self.json(401, dict(error=dict(type='invalid_session', message='Synthetic source sign-in required')))
        elif source == 'slow' and route in ('/api/nodes', '/api/attention', '/api/delegations'):
            with self.server.state_lock:
                if route == '/api/nodes':
                    self.server.slow_nodes_pending += 1
            self.record(path, 'stalled')
            try:
                if not self.server.stopping.wait(self.server.stall_seconds):
                    self.json(504, dict(error=dict(type='fixture_timeout', message='Synthetic slow source')))
            finally:
                with self.server.state_lock:
                    if route == '/api/nodes':
                        self.server.slow_nodes_pending -= 1
        elif source != 'direct' and route == '/api/nodes':
            node = hub_node(source)
            if mode == 'delayed-update':
                node['name'] = TITLES[source] + ' refreshed agent'
            if mode == 'offline':
                node['status'].update(reachable=False, state='offline')
            if source == 'home' and mode == 'pending-check':
                node['name'] = 'Home pending-check refresh'
            self.json(200, dict(nodes=[node]))
            if source == 'home' and mode == 'pending-check':
                with self.server.state_lock:
                    self.server.pending_check_healthy_completed = True
        elif source != 'direct' and route == '/api/attention':
            self.json(200, hub_attention(source, seen))
        elif source != 'direct' and route == '/api/delegations':
            self.json(200, dict(delegations=[]))
        elif route == '/api/auth/session':
            self.json(404, dict(error='No passkey authentication in this fixture'))
        elif (source == 'direct' and route == '/v1/sessions/search') or (source != 'direct' and route == '/node/shared/v1/sessions/search'):
            self.json(200, search_sessions(source, parse_qs(parts.query).get('q', [''])[0]))
        elif (source != 'direct' and route == '/node/shared/v1/sessions/status') or (
                source == 'direct' and route == '/v1/sessions/status' and 'ids' in parse_qs(parts.query)):
            self.json(200, status_for_ids(source, parse_qs(parts.query).get('ids', [''])[0]))
        elif source == 'direct' and route == '/v1/sessions/status':
            self.json(200, dict(sessions=[session(source, True), session(source)]))
        elif source == 'direct' and route == '/v1/attention':
            query = parse_qs(parts.query)
            kind = query.get('kind', [''])[0]
            if kind not in ('unseen', 'running', 'input_required'):
                self.json(400, dict(error=dict(message='kind is required')))
                return
            try:
                limit = int(query.get('limit', ['200'])[0])
            except ValueError:
                limit = 0
            if not 1 <= limit <= 500:
                self.json(400, dict(error=dict(message='Invalid limit')))
                return
            self.json(200, node_attention(source, kind, seen))
        elif route == '/':
            config = None if source == 'direct' else dict(page='dashboard', authMode='none',
                basePath='/' + source, canAddNodes=False, passkeyAuth=False, cacheDisplayAllowed=False)
            body = '<h1>' + TITLES[source] + ' fixture chat</h1><p>Static local HTML, not an LLM or real remote agent.</p>'
            self.send(200, legacy.page(body, config), 'text/html; charset=utf-8')
        elif (source == 'direct' and route.startswith('/chat/')) or (source != 'direct' and (route == '/node/shared' or route.startswith('/node/shared/'))):
            body = ('<header aria-label="Fixture agent header"><h1>' + TITLES[source] + ' fixture chat</h1></header>'
                    '<p>This route belongs to ' + SOURCES[source] + '.</p><p>' + html.escape(path) + '</p>'
                    '<a href="' + ('/' + source + '/node/shared/chat/1' if source != 'direct' else '/direct/chat/1') + '" aria-label="Open existing fixture conversation">Open existing conversation</a>'
                    '<p><input aria-label="Fixture draft" placeholder="Local fixture draft"></p>')
            self.send(200, legacy.page(body), 'text/html; charset=utf-8')
        else:
            self.json(404, dict(error='Unknown fixture route'))

    def do_POST(self):
        path = urlsplit(self.path).path
        if path.startswith('/__control/'):
            pieces = path.strip('/').split('/')
            if pieces == ['__control', 'slow', 'pending-asserted']:
                with self.server.state_lock:
                    valid = self.server.slow_nodes_pending > 0 and self.server.pending_check_healthy_completed
                self.json(200 if valid else 409, dict(fixture=True, pending=valid))
            elif pieces == ['__control', 'home', 'pending-check']:
                with self.server.state_lock:
                    self.server.source_modes['home'] = 'pending-check'
                    self.server.pending_check_healthy_completed = False
                self.json(200, dict(fixture=True, state='pending-check'))
            elif len(pieces) == 3 and pieces[1] in SOURCES and pieces[2] in ('healthy', 'unauthorized', 'offline', 'delayed-update'):
                with self.server.state_lock:
                    self.server.source_modes[pieces[1]] = pieces[2]
                self.json(200, dict(fixture=True, state=pieces[2]))
            else:
                self.json(400, dict(error='Unknown fixture control'))
            return
        pieces = path.strip('/').split('/')
        source = pieces[0]
        route = '/' + '/'.join(pieces[1:])
        if source not in SOURCES:
            self.json(404, dict(error='Unknown source'))
            return
        with self.server.state_lock:
            unauthorized = self.server.source_modes[source] == 'unauthorized'
        if unauthorized:
            self.json(401, dict(error=dict(type='invalid_session', message='Synthetic source sign-in required')))
            return
        try:
            length = int(self.headers.get('Content-Length', '0'))
        except ValueError:
            length = -1
        if not 0 <= length <= 16 * 1024:
            self.json(413, dict(error='Body too large'))
            return
        try:
            body = json.loads(self.rfile.read(length))
        except (ValueError, json.JSONDecodeError):
            self.json(400, dict(error='Invalid JSON'))
            return
        valid = body.get('store_instance_id') == 'store-' + source
        if source == 'direct' and route == '/v1/sessions/session-shared/attention/seen':
            valid = valid and body.get('through_seq') == 1
        elif source != 'direct' and route == '/api/attention/seen':
            valid = valid and body.get('session_id') == 'session-shared' and body.get('attention_seq') == 1
        else:
            self.json(405, dict(error='Only synthetic exact-item seen is supported'))
            return
        if not valid:
            self.json(409, dict(error='Synthetic marker mismatch'))
            return
        with self.server.state_lock:
            self.server.seen.add(source)
        self.json(200, dict(cleared=1) if source != 'direct' else dict(store_instance_id='store-direct', seen_through_seq=1, seen_rev=1))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--request-log', required=True)
    parser.add_argument('--port', type=int, default=8767)
    args = parser.parse_args()
    with PhoneFixtureServer(('127.0.0.1', args.port), args.request_log) as server:
        print(LABEL + ': local multi-source HTTP protocol fixture', flush=True)
        server.serve_forever()


if __name__ == '__main__':
    main()
