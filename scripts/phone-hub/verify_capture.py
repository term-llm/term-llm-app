#!/usr/bin/env python3
"""Reuse native capture gates and require both phone-Hub slices to execute."""
import importlib.util
import json
import os
from pathlib import Path
import sys

LEGACY = Path(__file__).resolve().parents[1] / 'native-hub'


def load(name):
    spec = importlib.util.spec_from_file_location('phone_reused_' + name, LEGACY / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


UNITS = ('HubConnectionStoreTests', 'HubAggregateStoreTests', 'DirectNodeClientTests',
         'DirectNodeClientModelTests', 'DirectNodeClientMountTests',
         'DirectNodeClientCookieFilterTests', 'HubConnectionSecurityTests',
         'ListenToolsTests', 'ListenPlayerTests', 'ListenStoreTests', 'ListenMediaTransportTests')
ROUTES = {'/work/api/nodes', '/home/api/nodes', '/work/api/attention', '/home/api/attention',
          '/direct/healthz', '/direct/v1/sessions/status', '/direct/v1/attention',
          '/work/node/shared/', '/home/node/shared/', '/direct/', '/slow/api/nodes'}
TESTS = ('testSavedConnectionsAndUnifiedViews', 'testSlowAndUnauthorizedSourcesDoNotBlockHealthySources')


def verify_pending_progress(requests):
    """Require a fresh native render and client-pending assertion, not server wait alone.

    The XCUITest changes Home's node title, waits for that uncached title, then
    asserts Slow's actual nodesLoading AX marker before posting pending-asserted.
    A passing xcresult plus this ordered trace covers the client timeout gap.
    """
    acknowledged = [i for i, row in enumerate(requests)
                    if row['path'] == '/__control/slow/pending-asserted' and row['status'] == 200]
    for end in acknowledged:
        starts = [i for i, row in enumerate(requests[:end])
                  if row['path'] == '/slow/api/nodes' and row['status'] == 'stalled']
        if not starts:
            continue
        start = starts[-1]
        window = requests[start + 1:end]
        if any(row['path'] == '/slow/api/nodes' and isinstance(row['status'], int) for row in window):
            continue
        armed = next((i for i, row in enumerate(window)
                      if row['path'] == '/__control/home/pending-check' and row['status'] == 200), None)
        if armed is not None and any(row['path'] == '/home/api/nodes' and row['status'] == 200
                                     for row in window[armed + 1:]):
            return
    raise ValueError('No fresh healthy render with native slow-request pending assertion')


def verify(root, device):
    root = Path(root)
    load('verify_units').verify_units(root, UNITS)
    load('verify_units').verify_units(root, ('PhoneHubUITests',), summary_file='test-summary.json', tree_file='test-tree.json')
    tree = json.loads((root / 'test-tree.json').read_text())
    def nodes(items):
        for item in items:
            yield item
            yield from nodes(item.get('children', []))
    cases = [item for item in nodes(tree.get('testNodes', [])) if item.get('nodeType') == 'Test Case' and item.get('result') == 'Passed']
    for name in TESTS:
        if not any(name in item.get('name', '') for item in cases):
            raise ValueError('Missing actually executed phone Hub journey: ' + name)
    load('verify_capture').verify(root, device, required_routes=ROUTES,
        stalled_path='/slow/api/nodes', refresh_path='/home/api/nodes',
        min_pngs=10, video_filename='phone-hub-demo-fixture.mp4')
    requests = [json.loads(line) for line in (root / 'fixture-requests.jsonl').read_text().splitlines()]
    verify_pending_progress(requests)
    denied = next((i for i, request in enumerate(requests) if request['path'] == '/work/api/nodes' and request['status'] == 401), None)
    if denied is None:
        raise ValueError('No actual single-source 401 observed')
    if not any(request['path'] == '/home/api/nodes' and request['status'] == 200 for request in requests[denied + 1:]):
        raise ValueError('No healthy source refresh after another source was unauthorized')
    print('Validated both slices, duplicate-ID source routing, pending-source and auth-failure isolation')


if __name__ == '__main__':
    verify(sys.argv[1], os.environ['SIMULATOR_UDID'])
