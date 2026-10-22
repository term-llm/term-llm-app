#!/usr/bin/env python3
"""Offline structural/JS bridge checks. NOT Swift compilation or XCTest."""
import datetime
import hashlib
import json
import pathlib
import plistlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]


def check_project():
    group = "group.com.termllm.app.shared"
    for name in ("TermLLM", "TermLLMNotificationService"):
        data = plistlib.loads((ROOT / name / f"{name}.entitlements").read_bytes())
        assert data["com.apple.security.application-groups"] == [group]
    info = plistlib.loads((ROOT / "TermLLM/Info.plist").read_bytes())
    assert info["UIApplicationSceneManifest"]["UIApplicationSupportsMultipleScenes"] is True
    assert "com.termllm.app.notification" in info["NSUserActivityTypes"]
    project = (ROOT / "TermLLM.xcodeproj/project.pbxproj").read_text()
    definitions = re.findall(r"^\s*([A-F0-9]{24}) /\*[^\n]*?\*/ = ", project, re.M)
    assert len(definitions) == len(set(definitions)), "duplicate Xcode object IDs"
    builds = dict(re.findall(r"([A-F0-9]{24}) /\* ([^\n]+?) in Sources \*/ = \{isa = PBXBuildFile;", project))
    phases = dict(re.findall(r"([A-F0-9]{24}) /\* Sources \*/ = \{\s*isa = PBXSourcesBuildPhase;.*?files = \((.*?)\);", project, re.S))
    actual = {}
    for phase, entries in phases.items():
        ids = re.findall(r"([A-F0-9]{24}) /\*", entries)
        actual[phase[-3:]] = {builds[key] for key in ids}
    for name in ("PushDeliveryStore.swift", "PushMetadata.swift", "PushMessage.swift"):
        assert name in actual["050"] and name in actual["471"], name
        assert (ROOT / "Shared" / name).is_file(), name
    for name in ("PushWindowRegistry.swift", "NativePushNotifications.swift", "PushNotificationLifecycle.swift"):
        assert name in actual["050"], name
        assert (ROOT / "TermLLM" / name).is_file(), name
    assert "NotificationLifecycleTests.swift" in actual["053"]
    resource_phases = dict(re.findall(r"([A-F0-9]{24}) /\* Resources \*/ = \{\s*isa = PBXResourcesBuildPhase;.*?files = \((.*?)\);", project, re.S))
    fixture_phase = "000000000000000000000522"
    assert fixture_phase in resource_phases
    assert "ProducerFixtures in Resources" in resource_phases[fixture_phase]
    assert all("ProducerFixtures" not in files for phase, files in resource_phases.items() if phase != fixture_phase)
    test_target = re.search(r'000000000000000000000011 /\* TermLLMTests \*/ = \{(.*?)buildRules', project, re.S).group(1)
    assert fixture_phase in test_target, "fixtures must belong only to the test bundle"
    print("PASS: entitlement plists, unique Xcode IDs and notification target memberships (fixtures test-only)")


def check_producer_fixtures():
    root = ROOT / "TermLLMTests/ProducerFixtures"
    manifest = json.loads((root / "manifest.json").read_bytes())
    assert manifest["public_review_sha"] == "600d7199e30375758fefba7a0e57a4ae72f9a923"
    assert manifest["production_implementation_sha"] == "7f8b8251d0370fe7f475925b50ad7f46a8a697a2"
    assert manifest["synthetic_only"] and manifest["unmodified_producer_bytes"]
    assert manifest["credentials_or_endpoints_in_payload"] is False
    assert {entry["file"] for entry in manifest["fixtures"]} == {"completion.json", "completion-compact.json", "manual.json"}
    payloads = {}
    for entry in manifest["fixtures"]:
        raw = (root / entry["file"]).read_bytes()
        assert len(raw) == entry["bytes"], entry["file"]
        assert hashlib.sha256(raw).hexdigest() == entry["sha256"], entry["file"]
        payload = json.loads(raw)
        created = datetime.datetime.fromisoformat(payload["created_at"].replace("Z", "+00:00"))
        expires = datetime.datetime.fromisoformat(payload["expires_at"].replace("Z", "+00:00"))
        now = datetime.datetime.fromisoformat(entry["injected_test_now"].replace("Z", "+00:00"))
        assert created < now < expires, "use manifest clock, never rewrite producer timestamps"
        assert (expires - created).total_seconds() == (60 if entry["kind"] == "manual" else 86400)
        assert payload["kind"] == entry["kind"] and payload["source"] == entry["source"]
        assert payload["version"] == 2 and payload["event_id"]
        payloads[entry["file"]] = payload
    primary = dict(payloads["completion.json"])
    compact = dict(payloads["completion-compact.json"])
    assert primary.pop("title") != compact.pop("title")
    assert primary == compact, "compact producer must retain all identity/expiry/routing fields"
    manual = payloads["manual.json"]
    assert manual["body"] == "Build finished: all tests passed. 节点 😀 <&>\nNext step."
    assert not {"turn_id", "window_id", "store_instance_id", "attention_seq"}.intersection(manual)
    print("PASS: exact actual-producer hashes/provenance, compact identity, Unicode manual body and manifest clocks (manual TTL 60s)")


def check_injected_javascript():
    swift = (ROOT / "TermLLM/NativePushBridge.swift").read_text()
    source = re.search(r'static func script\(origin: String\).*?return """\n(.*?)\n\s*"""', swift, re.S).group(1)
    source = source.replace(r"\(literal(origin))", json.dumps("https://hub.example"))
    source = source.replace(r"\(literal(handlerName))", json.dumps("termllmPush"))
    assert "\\(" not in source, "unhandled Swift interpolation"
    test = r'''
import assert from 'node:assert/strict';
import vm from 'node:vm';
const source = SOURCE;
let incarnation = 0;
function page(origin = 'https://hub.example', handlerPresent = true) {
  const calls = [];
  const window = { TERM_LLM_UI_TITLE: 'Node A', TERM_LLM_HUB: { nodeBasePath: '/ui' } };
  if (handlerPresent) window.webkit = { messageHandlers: { termllmPush: {
    postMessage: async value => {
      calls.push(value);
      return value.method === 'notificationCapabilities'
        ? { version: 2, window_id: 'scene:owner', document_id: value.document_id } : true;
    },
  } } };
  const context = vm.createContext({ window, location: { origin }, crypto: { randomUUID: () => `document-${++incarnation}` } });
  vm.runInContext(source, context);
  return { window, calls };
}
const { window, calls } = page();
const bridge = window.__termLLMNativePush;
assert.equal(bridge.version, 1, 'enrollment compatibility remains v1');
assert.equal(Object.isFrozen(bridge), true);
await bridge.permission('/node/A');
await bridge.subscribe('/node/A', 'test-vapid-key');
assert.equal(calls[1].applicationServerKey, 'test-vapid-key');
assert.equal(calls[1].label, 'Node A');
assert.equal(calls[1].nodeBasePath, '/ui');
const caps = await bridge.notificationCapabilities();
assert.equal(caps.version, 2);
assert.equal(caps.document_id, window.__termLLMNativePushDocumentID);
const presence = { version: 2, source: '/node/A', window_id: caps.window_id,
  document_id: caps.document_id, sequence: 8, active: true, expires_at: '2026-10-22T12:00:30Z' };
await bridge.notificationPresence(presence);
assert.equal(calls.at(-1).payload, presence, 'no URL-based native attendance shortcut');
const read = { version: 2, source: '/node/A', store_instance_id: 'store', session_id: 'session', attention_seq: 7 };
await bridge.notificationRead(read);
assert.equal(calls.at(-1).payload, read);
assert.equal(calls.at(-1).scope, '/node/A');
const enrollment = { source: '/node/A', subscription_id: 'subscription' };
for (const method of ['notificationEnrollment', 'notificationPendingCleanup', 'notificationCleanupAcknowledged']) {
  await bridge[method](enrollment);
  assert.equal(calls.at(-1).method, method);
  assert.equal(calls.at(-1).scope, '/node/A');
  assert.equal(calls.at(-1).document_id, caps.document_id);
}
assert.notEqual(page().window.__termLLMNativePushDocumentID, caps.document_id, 'reload has fresh document ID');
assert.equal(page('https://foreign.example').window.__termLLMNativePush, undefined);
assert.equal(page('https://hub.example', false).window.__termLLMNativePush, undefined);
console.log('PASS: actual injected bridge JS compatibility, v2 payloads, reload identity and origin/handler gates (offline VM)');
'''
    subprocess.run(["node", "--input-type=module"], input=test.replace("SOURCE", json.dumps(source)), text=True, check=True, cwd=ROOT)


if __name__ == "__main__":
    check_project()
    check_producer_fixtures()
    check_injected_javascript()
    print("Swift/XCTest, signing, NSE scheduling and device scene behavior remain UNVERIFIED here.")
