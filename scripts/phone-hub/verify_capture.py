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


UNITS = ('HubConnectionStoreTests', 'HubAggregateStoreTests', 'DirectNodeClientTests', 'HubConnectionSecurityTests')
ROUTES = {'/work/api/nodes', '/home/api/nodes', '/work/api/attention', '/home/api/attention',
          '/direct/healthz', '/direct/v1/sessions/status', '/direct/v1/attention',
          '/work/node/shared/', '/home/node/shared/', '/direct/', '/slow/api/nodes'}
TESTS = ('testSavedConnectionsAndUnifiedViews', 'testSlowAndUnauthorizedSourcesDoNotBlockHealthySources')


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
    denied = next((i for i, request in enumerate(requests) if request['path'] == '/work/api/nodes' and request['status'] == 401), None)
    if denied is None:
        raise ValueError('No actual single-source 401 observed')
    if not any(request['path'] == '/home/api/nodes' and request['status'] == 200 for request in requests[denied + 1:]):
        raise ValueError('No healthy source refresh after another source was unauthorized')
    print('Validated both slices, duplicate-ID source routing, pending-source and auth-failure isolation')


if __name__ == '__main__':
    verify(sys.argv[1], os.environ['SIMULATOR_UDID'])
