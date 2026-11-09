import Combine
import CryptoKit
import Darwin
import Foundation
import UserNotifications
import WebKit
import XCTest
@testable import TermLLM

/// Confirmed round-one review failures. No live keychain/group, notification
/// center, UIApplication activation, relay registration or provider is used.
@MainActor
final class NotificationReviewRegressionTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var storage: ReviewConsentStorage!
    private var journal: PushConsentJournal!
    private var store: PushDeliveryStore!
    private let origin = "https://review-fixture.example"

    override func setUp() async throws {
        suite = "review-notification-\(UUID().uuidString)"
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suite)!
        storage = ReviewConsentStorage()
        journal = PushConsentJournal(storage: storage)
        store = PushDeliveryStore(url: directory.appendingPathComponent("state.json"), journal: journal)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: directory)
    }

    private func center(_ deliveries: PushDeliveryStore? = nil, inbox: FakePushInbox? = nil) -> PushCenter {
        let center = PushCenter(defaults: defaults, identities: PushIdentityStore(storage: InMemoryPushStorage()),
            authorizer: ReviewAuthorizer(), relayTransport: { _ in XCTFail("No registration expected"); throw PushError.relayUnavailable },
            registerForRemote: {}, deliveries: deliveries ?? store, inbox: inbox ?? FakePushInbox())
        center.activateScene = { _, _, _ in XCTFail("Unexpected scene activation") }
        center.supportsMultipleScenes = { true }
        return center
    }

    private func manual() -> PushMessage {
        PushMessage.message(from: ["title": "Manual", "body": "Actual legacy content"], origin: origin, scope: "/node/A")
    }

    private func automatic() -> PushMessage {
        let now = ISO8601DateFormatter().string(from: Date())
        let expires = ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))
        return PushMessage.message(from: ["version": 2, "kind": "completion", "event_id": "review-event", "turn_id": "turn",
            "response_id": "response", "window_id": "native_owner", "store_instance_id": "store", "session_id": "session",
            "attention_seq": 1, "run_epoch": 1, "outcome": "completed", "source": "/node/A", "created_at": now,
            "expires_at": expires, "url": "/node/A/chat/session"], origin: origin, scope: "/node/A", sourceID: "route")
    }

    func testGlobalOffMirrorFailureCannotBeOverwrittenByEnabledMirrorOnRestart() async throws {
        let first = center()
        let enabled = await first.setEnabled(true)
        XCTAssertTrue(enabled)
        try store.remember(origin: origin, scope: "/node/A", endpoint: "opaque-A", subscriptionID: "sub-A")
        try store.remember(origin: origin, scope: "/node/B", endpoint: "opaque-B", subscriptionID: "sub-B")
        store.writeData = { _, _ in throw ReviewStorageError.injected }
        let off = await first.setEnabled(false)
        XCTAssertFalse(off, "shared write failure is not reported as success")
        XCTAssertFalse(first.enabled)
        XCTAssertEqual(try journal.load()?.enabled, false, "durable journal precedes failed mirror")
        let stale = try JSONDecoder().decode(PushDeliveryStore.State.self, from: Data(contentsOf: XCTUnwrap(store.url)))
        XCTAssertEqual(stale.enabled, true, "fault injection must really leave the old enabled file")
        XCTAssertEqual(store.admit(manual()), .disabled, "NSE sees journal off even when mirror is unwritable")
        XCTAssertNotEqual(store.admit(automatic()), .allowed)
        let recovered = PushDeliveryStore(url: store.url, journal: journal)
        let restarted = center(recovered)
        XCTAssertFalse(restarted.enabled)
        XCTAssertEqual(try recovered.pending().count, 2)
        XCTAssertEqual(try recovered.transaction { $0.enabled }, false)
    }

    func testEnableCannotEraseUnmirroredOffOrItsCleanupHandles() throws {
        try store.migrate(enabled: true, optOuts: [])
        try store.remember(origin: origin, scope: "/node/A", endpoint: "opaque-A", subscriptionID: "sub-A")
        store.writeData = { _, _ in throw ReviewStorageError.injected }
        XCTAssertThrowsError(try store.persistConsent(enabled: false, optOuts: []))
        XCTAssertThrowsError(try store.persistConsent(enabled: true, optOuts: []))
        XCTAssertEqual(try journal.load()?.enabled, false, "failed enable must not overwrite unmirrored off")
        let recovered = PushDeliveryStore(url: store.url, journal: journal)
        try recovered.persistConsent(enabled: true, optOuts: [])
        XCTAssertEqual(try recovered.pending().first?.subscriptionID, "sub-A", "cleanup survives explicit re-enable")
        XCTAssertEqual(try journal.load()?.enabled, true)
    }

    func testRecoveredOffRetiresCachedEnrollmentEvenIfAppCrashedBeforeLegacyRecordUpdate() async throws {
        try store.migrate(enabled: true, optOuts: [])
        try store.remember(origin: origin, scope: "/node/A", endpoint: "opaque-A", subscriptionID: "sub-A")
        let key = PushCenter.scopeKey(origin: origin, scope: "/node/A")
        let record = PushCenter.Record(endpoint: "opaque-A", applicationServerKey: "unused", deviceToken: "unused",
            environment: .development, relay: "https://relay.invalid", retired: nil, subscriptionID: "sub-A")
        defaults.set(true, forKey: PushCenter.enabledKey)
        defaults.set(try JSONEncoder().encode([key: record]), forKey: PushCenter.recordsKey)
        _ = try journal.save(enabled: false, optOuts: []) // crash before mirror/legacy record update
        let restarted = center()
        XCTAssertFalse(restarted.enabled)
        XCTAssertEqual(restarted.records[key]?.retired, true)
        _ = await restarted.setEnabled(true)
        XCTAssertEqual(try store.pending().first?.subscriptionID, "sub-A")
        XCTAssertEqual(restarted.records[key]?.retired, true)
    }

    func testLegacyExplicitOffMigratesBeforeExistingEnabledMirrorCanOverrideIt() throws {
        let old = PushDeliveryStore(url: store.url)
        try old.migrate(enabled: true, optOuts: [])
        defaults.set(false, forKey: PushCenter.enabledKey)
        defaults.set([origin + "|/node/A"], forKey: PushCenter.optOutsKey)
        let restarted = center()
        XCTAssertFalse(restarted.enabled)
        XCTAssertEqual(try journal.load()?.enabled, false)
        XCTAssertTrue(try XCTUnwrap(journal.load()).optOuts.contains(origin + "|/node/A"))
    }

    func testScopedOffMirrorFailureRejectsBridgeAndSurvivesRestart() async throws {
        let first = center()
        _ = await first.setEnabled(true)
        store.writeData = { _, _ in throw ReviewStorageError.injected }
        let result = await NativePushBridge.handle(body: ["method": "disable", "scope": "/node/A"],
            frameOrigin: origin, isMainFrame: true, expectedOrigin: origin, center: first,
            documentURL: URL(string: origin + "/node/A/chat/session"))
        XCTAssertThrowsError(try result.get(), "bridge must reject instead of falsely resolving true")
        XCTAssertTrue(try XCTUnwrap(journal.load()).optOuts.contains(origin + "|/node/A"))
        XCTAssertEqual(store.admit(manual()), .disabled)
        var sibling = manual(); sibling.scope = "/node/B"
        XCTAssertEqual(store.admit(sibling), .allowed, "known journal consent preserves other manual scopes")
        let recovered = PushDeliveryStore(url: store.url, journal: journal)
        let restarted = center(recovered)
        await restarted.refreshAuthorization()
        XCTAssertEqual(restarted.permission(origin: origin, scope: "/node/A"), .default)
        XCTAssertEqual(restarted.permission(origin: origin, scope: "/node/B"), .granted)
        let unknown = PushDeliveryStore(url: nil, journal: journal)
        XCTAssertEqual(unknown.admit(manual()), .disabled, "missing app group cannot erase journal opt-out")
        XCTAssertNotEqual(unknown.admit(automatic()), .allowed)
    }

    func testScopedOffCanClearOnlyItsOwnCardsEvenWhenMirrorWriteFailed() async {
        let inbox = FakePushInbox()
        let first = center(inbox: inbox)
        _ = await first.setEnabled(true)
        var sibling = manual(); sibling.scope = "/node/B"
        func request(_ id: String, _ message: PushMessage) -> UNNotificationRequest {
            let content = UNMutableNotificationContent(); content.userInfo = message.userInfo
            return UNNotificationRequest(identifier: id, content: content, trigger: nil)
        }
        inbox.items = [request("A", manual()), request("B", sibling)]
        inbox.pendingItems = inbox.items
        store.writeData = { _, _ in throw ReviewStorageError.injected }
        XCTAssertFalse(first.disable(origin: origin, scope: "/node/A"))
        await first.clearNotifications(origin: origin, scope: "/node/A")
        XCTAssertEqual(Set(inbox.removedDelivered), ["A"])
        XCTAssertEqual(Set(inbox.removedPending), ["A"])
    }

    func testJournalFailureRejectsDisableAndCannotAdvertiseCapability() async throws {
        let first = center()
        _ = await first.setEnabled(true)
        storage.failWrites = true
        let result = await NativePushBridge.handle(body: ["method": "disable", "scope": "/node/A"],
            frameOrigin: origin, isMainFrame: true, expectedOrigin: origin, center: first)
        XCTAssertThrowsError(try result.get())
        XCTAssertNotNil(first.storageIssue)
        let caps = await NativePushBridge.handle(body: ["method": "notificationCapabilities", "scope": "", "document_id": "document"],
            frameOrigin: origin, isMainFrame: true, expectedOrigin: origin, center: first, windowID: "native_owner", documentID: "document")
        XCTAssertThrowsError(try caps.get(), "never claim durable off or automatic support when journal write failed")
        XCTAssertEqual(try journal.load()?.enabled, true, "test does not pretend a failed journal write persisted")
        XCTAssertNotNil(defaults.data(forKey: PushCenter.pendingConsentKey), "explicit failed off request retains a local retry marker")
        storage.failWrites = false
        let recovered = center(PushDeliveryStore(url: store.url, journal: journal))
        await recovered.refreshAuthorization()
        XCTAssertEqual(recovered.permission(origin: origin, scope: "/node/A"), .default)
        XCTAssertEqual(recovered.permission(origin: origin, scope: "/node/B"), .granted)
        XCTAssertNil(defaults.data(forKey: PushCenter.pendingConsentKey))
        XCTAssertTrue(try XCTUnwrap(journal.load()).optOuts.contains(origin + "|/node/A"))
    }

    func testGlobalJournalFailureRetainsRetryIntentAcrossRecoveryAndRestart() async throws {
        let first = center()
        _ = await first.setEnabled(true)
        storage.failWrites = true
        let result = await first.setEnabled(false)
        XCTAssertFalse(result)
        XCTAssertNotNil(defaults.data(forKey: PushCenter.pendingConsentKey))
        XCTAssertEqual(try journal.load()?.enabled, true)
        storage.failWrites = false
        let restarted = center(PushDeliveryStore(url: store.url, journal: journal))
        XCTAssertFalse(restarted.enabled)
        XCTAssertEqual(try journal.load()?.enabled, false)
        XCTAssertNil(defaults.data(forKey: PushCenter.pendingConsentKey))
    }

    func testBoundedNonblockingLockAndManualConsentPolicy() throws {
        try store.migrate(enabled: true, optOuts: [])
        let lockURL = try XCTUnwrap(store.url).appendingPathExtension("lock")
        let fd = open(lockURL.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { flock(fd, LOCK_UN); close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let receiver = PushDeliveryStore(url: store.url, journal: journal, lockAttempts: 1)
        XCTAssertThrowsError(try receiver.transaction { _ in true }) { error in
            XCTAssertEqual(error as? PushDeliveryStore.Failure, .lock)
        }
        XCTAssertEqual(receiver.admit(automatic()), .unavailable)
        XCTAssertEqual(receiver.admit(manual()), .allowed, "readable explicit journal consent, not automatic fail-open")
        _ = try journal.save(enabled: false, optOuts: [])
        XCTAssertEqual(receiver.admit(manual()), .disabled)
        let unreadable = PushDeliveryStore(url: store.url, lockAttempts: 1)
        XCTAssertEqual(unreadable.admit(manual()), .unavailable, "locked existing state with no readable journal is not unknown/new consent")
    }

    func testUnknownBeforeFirstLaunchAndMissingGroupPreserveOnlyManualCompatibility() throws {
        let identities = PushIdentityStore(storage: InMemoryPushStorage())
        var malformedInfo = manual().userInfo
        malformedInfo[PushMetadata.key] = "invalid metadata"
        XCTAssertNil(PushMessage.delivered(userInfo: malformedInfo), "damaged typed metadata cannot be downgraded to manual")
        let identity = try identities.loadOrCreate()
        try identities.setRoute(tag: "manual", origin: origin, scope: "/node/A")
        let payload = try relayedPayload(#"{"title":"Manual","body":"Actual legacy content"}"#, identity: identity, tag: "manual")
        let content = UNMutableNotificationContent(); content.userInfo = payload
        let request = UNNotificationRequest(identifier: "manual-request", content: content, trigger: nil)
        let bundle = Bundle(for: Self.self)
        let manifestURL = try XCTUnwrap(bundle.url(forResource: "manifest", withExtension: "json", subdirectory: "ProducerFixtures"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        let entries = try XCTUnwrap(manifest["fixtures"] as? [[String: Any]])
        let entry = try XCTUnwrap(entries.first { $0["file"] as? String == "manual.json" })
        let now = try XCTUnwrap((entry["injected_test_now"] as? String).flatMap(PushMetadata.date))
        let manualURL = try XCTUnwrap(bundle.url(forResource: "manual", withExtension: "json", subdirectory: "ProducerFixtures"))
        let typedPayload = try relayedPayload(String(decoding: Data(contentsOf: manualURL), as: UTF8.self), identity: identity, tag: "manual")
        let typed = try PushMessage.decode(userInfo: typedPayload, identity: identities.load())
        XCTAssertEqual(typed.metadata?.kind, "manual")
        for receiver in [store!, PushDeliveryStore(url: nil, journal: journal)] {
            let decoded = try PushMessage.content(for: request, identities: identities, deliveries: receiver)
            XCTAssertEqual(decoded.body, "Actual legacy content")
            XCTAssertEqual(decoded.userInfo[PushMessage.dispositionKey] as? String, "allowed")
            XCTAssertEqual(receiver.admit(typed, now: now), .allowed, "actual 60s manual producer uses manifest clock, never wall clock")
            XCTAssertEqual(receiver.admit(automatic()), .unavailable)
        }
        XCTAssertFalse(store.automaticStateAvailable, "unknown consent cannot advertise v2 automatic support")
        _ = try journal.save(enabled: false, optOuts: [])
        let disabled = try PushMessage.content(for: request, identities: identities, deliveries: PushDeliveryStore(url: nil, journal: journal))
        XCTAssertEqual(disabled.body, "")
        XCTAssertEqual(disabled.userInfo[PushMessage.dispositionKey] as? String, "disabled")
        storage.failReads = true
        XCTAssertEqual(PushDeliveryStore(url: nil, journal: journal).admit(manual()), .unavailable,
                       "unreadable shared keychain is not proof that no opt-out exists")
    }

    func testManualTapUsesKeySceneWithoutCreatingSceneAndCompletionNeverUsesIt() throws {
        let first = center()
        first.windows.keyWindowOverride = { "native_key" }
        first.open(urlString: origin + "/node/A/", configuredServer: URL(string: origin))
        XCTAssertEqual(first.pendingNavigation?.windowID, "native_key")
        XCTAssertEqual(first.pendingNavigation?.isCompletion, false)
        first.windows.keyWindowOverride = { nil }
        first.open(urlString: origin + "/node/A/", configuredServer: URL(string: origin))
        XCTAssertNil(first.pendingNavigation?.windowID, "cold manual tap waits for key scene")
        first.windows.keyWindowOverride = { "native_key" }
        first.routeManualToKeyScene()
        XCTAssertEqual(first.pendingNavigation?.windowID, "native_key")
        var activation: NSUserActivity?
        first.activateScene = { session, activity, _ in XCTAssertNil(session); activation = activity }
        first.open(urlString: origin + "/node/A/chat/session", configuredServer: URL(string: origin), windowID: "native_closed", isCompletion: true)
        XCTAssertNil(first.pendingNavigation?.windowID)
        first.routeManualToKeyScene()
        XCTAssertNil(first.pendingNavigation?.windowID, "owner-gone completion cannot fall back to key sibling")
        first.claimNavigation(try XCTUnwrap(activation), windowID: "native_key")
        XCTAssertNil(first.pendingNavigation, "UIKit reuse of an existing scene is not a fresh-owner destination")
        XCTAssertNotNil(first.navigationIssue)
        XCTAssertEqual(first.unroutedNavigation?.url.absoluteString, origin + "/node/A/chat/session",
                       "offered to the user instead of silently substituted")
        first.open(urlString: origin + "/node/A/chat/session", configuredServer: URL(string: origin), windowID: "native_closed", isCompletion: true)
        first.claimNavigation(try XCTUnwrap(activation), windowID: "native_fresh")
        XCTAssertEqual(first.pendingNavigation?.windowID, "native_fresh")
    }

    func testSingleSceneOwnerGoneCompletionRoutesToSoleSceneWithoutActivation() {
        let first = center()
        first.supportsMultipleScenes = { false }
        first.windows.keyWindowOverride = { nil }
        first.open(urlString: origin + "/node/A/chat/session", configuredServer: URL(string: origin),
                   windowID: "native_gone", isCompletion: true)
        XCTAssertNil(first.pendingNavigation?.windowID, "cold launch waits for the sole scene")
        XCTAssertNil(first.navigationIssue)
        first.windows.keyWindowOverride = { "native_sole" }
        first.routeManualToKeyScene()
        XCTAssertEqual(first.pendingNavigation?.windowID, "native_sole")
        XCTAssertNil(first.navigationIssue)
    }

    func testMultiSceneOwnerGoneWithEveryWindowClosedUsesLaunchingScene() {
        let first = center() // multi-scene; activation would XCTFail
        first.windows.keyWindowOverride = { nil }
        first.open(urlString: origin + "/node/A/chat/session", configuredServer: URL(string: origin),
                   windowID: "native_gone", isCompletion: true)
        XCTAssertNil(first.pendingNavigation?.windowID)
        first.windows.keyWindowOverride = { "native_launch" }
        first.routeManualToKeyScene()
        XCTAssertEqual(first.pendingNavigation?.windowID, "native_launch")
        XCTAssertNil(first.navigationIssue)
    }

    /// UIKit rejects every activation request in single-scene mode, even for the
    /// existing foreground scene (UISceneErrorDomain 0). That rejection used to
    /// drop the tap and show an error whenever it beat the page load.
    #if os(iOS)
    func testSingleSceneCompletionWithLiveOrRestorableOwnerNeverRequestsActivation() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                                  "hosted tests run in the app's scene")
        let owner = PushCenter.windowID(for: scene)
        let target = origin + "/node/A/chat/session"
        // The same owner lookup requests activation in multi-scene mode.
        let multi = center()
        multi.windows.register(windowID: owner, scene: scene)
        var activated: UISceneSession?
        multi.activateScene = { session, _, _ in activated = session }
        multi.open(urlString: target, configuredServer: URL(string: origin), windowID: owner, isCompletion: true)
        XCTAssertEqual(activated?.persistentIdentifier, scene.session.persistentIdentifier)

        let live = center() // activation would XCTFail
        live.supportsMultipleScenes = { false }
        live.windows.register(windowID: owner, scene: scene)
        live.open(urlString: target, configuredServer: URL(string: origin), windowID: owner, isCompletion: true)
        XCTAssertEqual(live.pendingNavigation?.windowID, owner, "the only scene is the owner")
        XCTAssertEqual(live.pendingNavigation?.isCompletion, false)
        XCTAssertEqual(live.pendingNavigation?.url.absoluteString, target)
        XCTAssertNil(live.navigationIssue)

        // Relaunch after iOS ended the process: the session is restorable but
        // its scene has not attached yet. Wait for it instead of activating.
        defaults.set([owner: scene.session.persistentIdentifier], forKey: PushCenter.windowSessionsKey)
        let restored = center()
        restored.supportsMultipleScenes = { false }
        restored.windows.keyWindowOverride = { nil }
        restored.open(urlString: target, configuredServer: URL(string: origin), windowID: owner, isCompletion: true)
        XCTAssertNil(restored.pendingNavigation?.windowID)
        restored.windows.keyWindowOverride = { owner }
        restored.routeManualToKeyScene()
        XCTAssertEqual(restored.pendingNavigation?.windowID, owner)
        XCTAssertNil(restored.navigationIssue)
    }

    #endif

    func testSceneActivationFailureOffersTheShownSceneInsteadOfDroppingTheTap() async throws {
        let first = center()
        first.windows.keyWindowOverride = { "native_sibling" }
        let surfaced = expectation(description: "activation error surfaced")
        let observation = first.$navigationIssue.compactMap { $0 }.sink { _ in surfaced.fulfill() }
        defer { observation.cancel() }
        first.activateScene = { _, _, failed in failed(ReviewStorageError.injected) }
        first.open(urlString: origin + "/node/A/chat/session", configuredServer: URL(string: origin), windowID: "native_closed", isCompletion: true)
        await fulfillment(of: [surfaced], timeout: 5)
        observation.cancel()
        XCTAssertNil(first.pendingNavigation, "never substituted without the user's choice")
        XCTAssertNotNil(first.navigationIssue)
        let unrouted = try XCTUnwrap(first.unroutedNavigation)
        XCTAssertEqual(unrouted.url.absoluteString, origin + "/node/A/chat/session")

        first.openHere(unrouted, windowID: "native_sibling")
        XCTAssertEqual(first.pendingNavigation?.windowID, "native_sibling")
        XCTAssertEqual(first.pendingNavigation?.url, unrouted.url)
        XCTAssertEqual(first.pendingNavigation?.isCompletion, false)
        XCTAssertNotEqual(first.pendingNavigation?.id, unrouted.id, "a stale activity cannot claim the new route")
        XCTAssertNil(first.navigationIssue)
        XCTAssertNil(first.unroutedNavigation)

        var activity: NSUserActivity?
        first.activateScene = { _, value, _ in activity = value }
        first.open(urlString: origin + "/node/A/chat/other", configuredServer: URL(string: origin), windowID: "native_closed", isCompletion: true)
        first.claimNavigation(try XCTUnwrap(activity), windowID: "native_sibling")
        XCTAssertEqual(first.unroutedNavigation?.url.absoluteString, origin + "/node/A/chat/other",
                       "iOS reusing an existing window offers the page too")
        first.dismissNavigationIssue()
        XCTAssertNil(first.navigationIssue)
        XCTAssertNil(first.unroutedNavigation)
        XCTAssertNil(first.pendingNavigation, "dismissing does not open the page anywhere")
    }

    func testCommittedDocumentInvalidatesButProvisionalFailureDoesNotNeedRebinding() {
        let first = center()
        first.windows.sceneIsActive = { _ in true }
        first.windows.bind(windowID: "native_owner", documentID: "old", origin: origin)
        let bridge = NativePushBridge(serverURL: URL(string: origin)!, center: first)
        XCTAssertTrue(first.windows.update(windowID: "native_owner", documentID: "old", origin: origin, sequence: 1,
            active: true, expires: Date().addingTimeInterval(30)))
        // No commit occurs for provisional failure/cancel/download. Existing
        // document continues publishing; real coordinator path is tested too.
        XCTAssertTrue(first.windows.update(windowID: "native_owner", documentID: "old", origin: origin, sequence: 2,
            active: true, expires: Date().addingTimeInterval(30)))
        bridge.documentCommitted(windowID: "native_owner")
        XCTAssertEqual(bridge.documentGeneration, 1)
        XCTAssertFalse(first.windows.update(windowID: "native_owner", documentID: "old", origin: origin, sequence: 3,
            active: true, expires: Date().addingTimeInterval(30)))
        first.windows.bind(windowID: "native_owner", documentID: "new", origin: origin)
        XCTAssertTrue(first.windows.update(windowID: "native_owner", documentID: "new", origin: origin, sequence: 1,
            active: true, expires: Date().addingTimeInterval(30)))
    }

    func testOnlyKeySceneCanClaimGlobalVoiceRequestOnce() throws {
        let voice = VoiceLaunchCenter()
        voice.requestLaunch()
        let id = try XCTUnwrap(voice.request)
        XCTAssertFalse(voice.claim(id, windowID: "background", isKeyScene: false))
        XCTAssertTrue(voice.claim(id, windowID: "key", isKeyScene: true))
        XCTAssertFalse(voice.claim(id, windowID: "key", isKeyScene: true), "one observer claim, even if multiple view copies share an ID")
        XCTAssertFalse(voice.claim(id, windowID: "other", isKeyScene: true))
        XCTAssertEqual(voice.ownerWindowID, "key")
        voice.finish()
        XCTAssertNil(voice.ownerWindowID)
    }

    func testActualNativeEncoderMatchesSharedSafeHTTPContractFixture() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "native-identity-contract", withExtension: "json", subdirectory: "ProducerFixtures"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let vectors = try XCTUnwrap(object["vectors"] as? [[String: String]])
        var ids = Set<String>()
        for vector in vectors {
            let persistent = try XCTUnwrap(vector["persistent_identifier"])
            let actual = PushWindowRegistry.identifier(persistentIdentifier: persistent)
            XCTAssertEqual(actual, vector["window_id"])
            XCTAssertEqual(actual.count, 50)
            XCTAssertNotNil(actual.range(of: "^[A-Za-z0-9_-]{8,100}$", options: .regularExpression))
            XCTAssertEqual(actual, PushWindowRegistry.identifier(persistentIdentifier: persistent))
            ids.insert(actual)
        }
        XCTAssertEqual(ids.count, vectors.count)
    }
}

private enum ReviewStorageError: Error { case injected }
private final class ReviewConsentStorage: PushSecretStorage {
    var data: Data?
    var failReads = false
    var failWrites = false
    func read() throws -> Data? { if failReads { throw ReviewStorageError.injected }; return data }
    func write(_ data: Data) throws { if failWrites { throw ReviewStorageError.injected }; self.data = data }
}
private struct ReviewAuthorizer: PushAuthorizer {
    func status() async -> UNAuthorizationStatus { .authorized }
    func request() async throws -> Bool { true }
}
