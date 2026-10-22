#!/usr/bin/env python3
"""Offline structural/JS bridge checks. NOT Swift compilation or XCTest."""
import base64
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
    assert info["UIApplicationSceneManifest"]["UIApplicationSupportsMultipleScenes"] is False
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
    for name in ("PushDeliveryStore.swift", "PushConsentJournal.swift", "PushMetadata.swift", "PushMessage.swift"):
        assert name in actual["050"] and name in actual["471"], name
        assert (ROOT / "Shared" / name).is_file(), name
    for name in ("PushWindowRegistry.swift", "NativePushNotifications.swift", "PushNotificationLifecycle.swift"):
        assert name in actual["050"], name
        assert (ROOT / "TermLLM" / name).is_file(), name
    assert "NotificationLifecycleTests.swift" in actual["053"]
    assert "NotificationReviewRegressionTests.swift" in actual["053"]
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



def check_native_review_contract():
    root = ROOT / "TermLLMTests/ProducerFixtures"
    contract = json.loads((root / "native-identity-contract.json").read_bytes())
    assert contract["accepted_pattern"] == "^[A-Za-z0-9_-]{8,100}$"
    for vector in contract["vectors"]:
        encoded = "native_" + base64.urlsafe_b64encode(hashlib.sha256(vector["persistent_identifier"].encode()).digest()).decode().rstrip("=")
        assert encoded == vector["window_id"] and len(encoded) == 50
        assert re.fullmatch(contract["accepted_pattern"], encoded)
    registry = (ROOT / "TermLLM/PushWindowRegistry.swift").read_text()
    assert '"native_" + Data(SHA256.hash(data: Data(persistentIdentifier.utf8))).base64URLEncodedString()' in registry
    center = (ROOT / "TermLLM/PushCenter.swift").read_text()
    assert "PushWindowRegistry.identifier(persistentIdentifier: scene.session.persistentIdentifier)" in center
    assert "Self.pendingConsentKey" in center and "decode(PushConsentJournal.Snapshot.self" in center
    assert "navigation.excludedWindowIDs.contains(windowID)" in center
    assert "errorHandler: failed" in center and "navigationIssue" in center
    opened = center.split("    func open(", 1)[1].split("    func routeManualToKeyScene", 1)[0]
    assert opened.index("guard completion else { return }") < opened.index("activateScene(session, activity)")
    bridge = (ROOT / "TermLLM/NativePushBridge.swift").read_text()
    assert "guard center.disable(" in bridge and "guard center.unsubscribe(" in bridge
    coordinator = (ROOT / "TermLLM/BrowserView.swift").read_text()
    provisional = coordinator.split("didStartProvisionalNavigation", 1)[1].split("didCommit", 1)[0]
    assert "documentCommitted(" not in provisional
    assert "documentCommitted(" in coordinator.split("didCommit", 1)[1].split("didFinish", 1)[0]
    store = (ROOT / "Shared/PushDeliveryStore.swift").read_text()
    assert "flock(fd, LOCK_EX | LOCK_NB)" in store and "flock(fd, LOCK_EX)" not in store
    assert "max(1, min(lockAttempts, 40))" in store and "usleep(5_000)" in store
    persist = store.split("    func persistConsent(", 1)[1].split("    func setEnabled(", 1)[0]
    assert persist.index("journal?.save") < persist.index("try transaction")
    assert "if clearsPriorOff { try reconcilePriorOffMirror() }" in persist
    capabilities = (ROOT / "TermLLM/NativePushNotifications.swift").read_text()
    assert "center.deliveries.automaticStateAvailable" in capabilities
    fallback = store.split("    private func unavailablePolicy(", 1)[1].split("    func admit(", 1)[0]
    assert 'guard message.metadata?.kind != "completion" else { return .unavailable }' in fallback
    metadata = (ROOT / "Shared/PushMetadata.swift").read_text()
    assert "expires.timeIntervalSince(created) <= PushDeliveryStore.horizon" in metadata
    assert 'padding(toLength: 3, withPad: "0"' in metadata
    assert "(metadata.runEpoch ?? 0) > 0" in metadata
    voice = (ROOT / "TermLLM/ContentView.swift").read_text()
    assert "isKeyScene: push.isKeyScene(pushWindowID)" in voice
    print("PASS: safe native-ID vectors and scoped source guards for journal-first writes, bounded locks, commit-only invalidation and manual/key-scene routing (structural, NOT Swift execution)")


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
        ? { version: 2, window_id: OWNER_ID, document_id: value.document_id } : true;
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
assert.match(caps.window_id, /^[A-Za-z0-9_-]{8,100}$/);
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
    subprocess.run(["node", "--input-type=module"], input=test.replace("SOURCE", json.dumps(source)).replace("OWNER_ID", json.dumps(json.loads((ROOT / "TermLLMTests/ProducerFixtures/native-identity-contract.json").read_bytes())["vectors"][0]["window_id"])), text=True, check=True, cwd=ROOT)


if __name__ == "__main__":
    check_project()
    check_producer_fixtures()
    check_native_review_contract()
    check_injected_javascript()
    print("Swift/XCTest, signing, NSE scheduling and device scene behavior remain UNVERIFIED here.")
