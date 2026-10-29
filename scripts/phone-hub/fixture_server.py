#!/usr/bin/env python3
"""Loopback-only MULTI-SOURCE PROTOCOL FIXTURE. Not real agents or authentication.

Reuses native-hub fixture HTML/response/logging helpers. Wire fields are from
core 2496b5fd (unchanged through 5147a9f6 for direct attention/session APIs).
Three sources deliberately collide on remote node/session/attention identifiers.
"""
import argparse
import base64
import binascii
import html
from http.server import ThreadingHTTPServer
import importlib.util
import json
from pathlib import Path
import re
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


def session_corpus(source):
    """Mutable node sessions, separate from the deliberately tiny dashboard."""
    titles = '''Kyoto day plan
Fix flaky WebRTC reconnect test
Plan the autumn vegetable garden
Review accessibility labels
Prepare weekend cycling route
Compare home backup options
Draft team onboarding checklist
Benchmark SQLite FTS rebuild
Tune podcast audio levels
Organize family photo archive
Investigate slow launch trace
Sketch kitchen renovation budget
Write release migration guide
Review push relay retry policy
Plan a coastal walking holiday
Improve offline error messages
Audit dependency licenses
Practice conversational Japanese
Design weekly meal planner
Debug calendar timezone drift
Research balcony solar panels
Clean up stale feature flags
Build a reading list
Profile image thumbnail cache
Prepare conference talk outline
Refine search result snippets
Review database vacuum schedule
Plan a birthday dinner
Trace intermittent DNS failures
Compare train routes to Osaka
Update emergency contact sheet
Simplify deployment checklist
Explore local hiking trails
Measure cold startup latency
Draft community newsletter
Check keyboard navigation
Organize workshop materials
Review API rate limits
Plan a living room bookshelf
Investigate memory growth
Write integration test fixtures
Prepare quarterly budget
Design a better empty state
Research coffee grinder settings
Tune background sync intervals
Outline a short story
Review account recovery flow
Plan spring camping trip
Compare encrypted backup tools
Fix subtitle timing drift
Draft volunteer schedule
Analyze battery usage report
Improve file upload progress
Create museum weekend itinerary
Document database indexes
Plan a small herb garden
Review streaming reconnect logic
Sort travel packing checklist
Benchmark JSON decoding
Prepare interview questions
Audit color contrast ratios
Explore neighborhood bike lanes
Write disaster recovery notes
Refine notification grouping
Plan a pottery class visit
Debug audio route switching
Organize tax receipts
Review pagination edge cases
Draft project retrospective
Compare lightweight rain jackets
Measure full text search latency
Plan a quiet reading weekend
Document release rollback steps'''.splitlines()
    count = 75 if source == 'home' else 2 if source == 'direct' else 5
    rows = {}
    reference = 1792735200000
    for number in range(1, count + 1):
        dashboard = session(source, number == 2) if number <= 2 else None
        title = dashboard['short_title'] if dashboard else titles[number - 3]
        if source in ('work', 'slow') and not dashboard:
            title = TITLES[source] + ' ' + title
        identifier = dashboard['id'] if dashboard else 'session-' + str(number)
        last_message = reference if dashboard else reference - (number - 2) * 2 * 86_400_000
        unseen = number == 1 or (source == 'home' and number in (8, 40))
        row = dict(id=identifier, number=number, short_title=title, long_title='',
                   archived=False, pinned=False, created_at=last_message - 86_400_000,
                   last_message_at=last_message, message_count=4 if dashboard else 2 + number * 17 % 119,
                   attention_store_instance_id='store-' + source, attention_seq=1 if unseen else 0,
                   seen_rev=0, attention_unseen=unseen, name='', _original_title=title)
        if number > 2 and number % 3 == 0:
            row['project_name'] = ('Travel', 'Home projects', 'Term LLM')[number % 9 // 3]
        rows[identifier] = row
    pins = (10, 3, 25) if source == 'home' else (3,) if source in ('work', 'slow') else ()
    for rank, number in enumerate(pins, 1):
        rows['session-' + str(number)].update(pinned=True, pin_order=rank)
    return rows


def session_entry(row):
    return {key: value for key, value in row.items() if key not in ('name', '_original_title')}


def session_order(row):
    return (0 if row['pinned'] else 1, row.get('pin_order', 0) if row['pinned'] else 0,
            -row['last_message_at'], -row['number'])


def session_cursor(source, offset):
    return base64.urlsafe_b64encode(json.dumps(dict(source=source, offset=offset)).encode()).decode().rstrip('=')


def cursor_offset(source, token):
    try:
        data = json.loads(base64.b64decode(token + '=' * (-len(token) % 4), altchars=b'-_', validate=True))
        if (isinstance(data, dict) and data.get('source') == source
                and type(data.get('offset')) is int and data['offset'] >= 0):
            return data['offset']
    except (ValueError, UnicodeError, binascii.Error):
        pass
    raise ValueError('Invalid session cursor')


def status_for_ids(source, raw_ids, corpus=None):
    """`/v1/sessions/status?ids=`: exactly the requested synthetic sessions."""
    wanted = [item for item in raw_ids.split(',') if item]
    rows = {'search-' + str(number): dict(id='search-' + str(number), number=number, short_title=short, long_title='',
                                         active_run=number == 11 and source == 'work', interaction_required=False,
                                         last_message_at=1792735200000 - number * 3_600_000, message_count=6)
            for number, short, _ in search_corpus(source)}
    for item in (session(source, True), session(source)):
        rows[item['id']] = item
    if corpus is not None:
        for item in corpus.values():
            active = item['id'] == 'active-shared'
            rows[item['id']] = dict(session_entry(item), active_run=active, interaction_required=active,
                                    pending_interaction_count=int(active),
                                    pending_interaction_kinds=['approval'] if active else [])
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
        self.sessions = {source: session_corpus(source) for source in SOURCES}
        self.sessions_page_errors = set()
        super().__init__(address, Handler)

    def server_close(self):
        self.stopping.set()
        super().server_close()


class Handler(legacy.Handler):
    def json(self, status, value):
        self.send(status, json.dumps(value).encode())

    def session_error(self, status, kind, message):
        self.json(status, dict(error=dict(type=kind, message=message)))

    def list_sessions(self, source, query):
        with self.server.state_lock:
            fail = 'cursor' in query and source in self.server.sessions_page_errors
            if fail:
                self.server.sessions_page_errors.remove(source)
        if fail:
            self.session_error(503, 'fixture_unavailable', 'Synthetic page failure')
            return
        if query.get('scope', ['all'])[0] != 'all':
            self.session_error(400, 'invalid_request_error', 'unsupported session scope')
            return
        try:
            offset = cursor_offset(source, query['cursor'][0]) if 'cursor' in query else 0
        except ValueError:
            self.session_error(400, 'invalid_cursor', 'session cursor does not belong to this session listing')
            return
        snapshot = 'limit' not in query and 'cursor' not in query
        raw_limit = query.get('limit', ['12'])[0]
        try:
            limit = int(raw_limit) if re.fullmatch(r'[+-]?[0-9]+', raw_limit) else 12
        except ValueError:
            limit = 12
        limit = min(limit, 100) if limit >= 1 else 12
        if snapshot:
            limit = 100
        with self.server.state_lock:
            rows = sorted((row for row in self.server.sessions[source].values() if not row['archived']),
                          key=session_order)
            result = dict(sessions=[session_entry(row) for row in rows[offset:offset + limit]], selected_session=None)
            if not snapshot and offset + limit < len(rows):
                result['next_cursor'] = session_cursor(source, offset + limit)
        self.json(200, result)

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
        sessions_route = '/v1/sessions' if source == 'direct' else '/node/shared/v1/sessions'
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
        elif mode == 'unauthorized' and (route.startswith('/api/') or route.startswith('/v1/') or route == sessions_route):
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
        elif path == '/' + source + sessions_route:
            self.list_sessions(source, parse_qs(parts.query, keep_blank_values=True))
        elif (source == 'direct' and route == '/v1/sessions/search') or (source != 'direct' and route == '/node/shared/v1/sessions/search'):
            self.json(200, search_sessions(source, parse_qs(parts.query).get('q', [''])[0]))
        elif (source != 'direct' and route == '/node/shared/v1/sessions/status') or (
                source == 'direct' and route == '/v1/sessions/status' and 'ids' in parse_qs(parts.query)):
            with self.server.state_lock:
                data = status_for_ids(source, parse_qs(parts.query).get('ids', [''])[0], self.server.sessions[source])
            self.json(200, data)
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

    def do_PATCH(self):
        pieces = urlsplit(self.path).path.strip('/').split('/')
        source = pieces[0]
        if source not in SOURCES:
            self.json(404, dict(error='Unknown fixture route'))
            return
        route = '/' + '/'.join(pieces[1:])
        prefix = '/v1/sessions/' if source == 'direct' else '/node/shared/v1/sessions/'
        with self.server.state_lock:
            unauthorized = self.server.source_modes[source] == 'unauthorized'
        if unauthorized:
            self.session_error(401, 'invalid_session', 'Synthetic source sign-in required')
            return
        if not route.startswith(prefix) or not route[len(prefix):] or '/' in route[len(prefix):]:
            self.json(405, dict(error='Only synthetic session updates are supported'))
            return
        if self.headers.get_content_type() != 'application/json':
            self.session_error(400, 'invalid_request_error', 'Content-Type must be application/json')
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
        except (ValueError, UnicodeError):
            self.session_error(400, 'invalid_request_error', 'Invalid JSON')
            return
        if not isinstance(body, dict):
            self.session_error(400, 'invalid_request_error', 'Expected a JSON object')
            return
        identifier = route[len(prefix):]
        if identifier == 'pinned-order':
            identifiers = body.get('session_ids')
            if (not isinstance(identifiers, list) or any(not isinstance(item, str) for item in identifiers)
                    or len(set(identifiers)) != len(identifiers)):
                self.session_error(400, 'invalid_request_error', 'session_ids must be a list of unique strings')
                return
        elif any(key in body and type(body[key]) is not kind
                 for key, kind in (('name', str), ('archived', bool), ('pinned', bool))):
            self.session_error(400, 'invalid_request_error', 'Invalid session update field type')
            return
        with self.server.state_lock:
            rows = self.server.sessions[source]
            if identifier == 'pinned-order':
                if any(item not in rows for item in identifiers):
                    status, result = 404, dict(error=dict(type='not_found_error', message='session not found'))
                elif any(not rows[item]['pinned'] for item in identifiers):
                    status, result = 409, dict(error=dict(type='conflict_error', message=
                        'a listed session is no longer pinned; refresh and try again'))
                else:
                    ranks = sorted(rows[item]['pin_order'] for item in identifiers)
                    for item, rank in zip(identifiers, ranks):
                        rows[item]['pin_order'] = rank
                    pins = sorted((row for row in rows.values() if row['pinned']), key=lambda row: row['pin_order'])
                    status, result = 200, dict(pinned=[dict(id=row['id'], pin_order=row['pin_order']) for row in pins])
            elif identifier not in rows:
                status, result = 404, dict(error=dict(type='not_found_error', message='session not found'))
            else:
                row = rows[identifier]
                if 'name' in body:
                    row['name'] = body['name'].strip()
                    row['short_title'] = row['name'] or row['_original_title']
                if 'archived' in body:
                    row['archived'] = body['archived']
                if 'pinned' in body:
                    if body['pinned'] and not row['pinned']:
                        row['pin_order'] = max((item.get('pin_order', 0) for item in rows.values()), default=0) + 1
                    elif not body['pinned']:
                        row.pop('pin_order', None)
                    row['pinned'] = body['pinned']
                result = {key: row[key] for key in ('id', 'name', 'short_title', 'long_title', 'archived', 'pinned', 'created_at')}
                result.update(pin_order=row.get('pin_order', 0), generated_short_title='', generated_long_title='',
                              mode='chat', origin='web')
                status = 200
        self.json(status, result)

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
            elif len(pieces) == 3 and pieces[1] in SOURCES and pieces[2] == 'sessions-page-error':
                with self.server.state_lock:
                    self.server.sessions_page_errors.add(pieces[1])
                self.json(200, dict(fixture=True, state='sessions-page-error'))
            elif len(pieces) == 3 and pieces[1] in SOURCES and pieces[2] in ('healthy', 'unauthorized', 'offline', 'delayed-update'):
                with self.server.state_lock:
                    self.server.source_modes[pieces[1]] = pieces[2]
                    if pieces[2] == 'healthy':
                        # UI tests reset every source before each test; pins,
                        # renames and archives must not leak between tests.
                        self.server.sessions[pieces[1]] = session_corpus(pieces[1])
                        self.server.sessions_page_errors.discard(pieces[1])
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
