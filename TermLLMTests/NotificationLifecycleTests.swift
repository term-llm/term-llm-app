import CryptoKit
import Foundation
import UserNotifications
import XCTest
@testable import TermLLM

// Every test uses a disposable directory, fake authorizer and fake inbox.
// No system registration, server enrollment, keychain or APNs calls.
final class PushDeliveryStoreTests: XCTestCase {
    private var directory: URL!
    private var store: PushDeliveryStore!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = PushDeliveryStore(url: directory.appendingPathComponent("state.json"))
        try store.migrate(enabled: true, optOuts: [])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testReplaySurvivesRestartAndKeepsDifferentTurnsIndependent() throws {
        let first = completionMessage(event: "event-1", now: now)
        XCTAssertEqual(try store.receive(first, now: now), .allowed)
        let restarted = PushDeliveryStore(url: store.url)
        XCTAssertEqual(try restarted.receive(first, now: now), .replay)
        XCTAssertEqual(try restarted.receive(completionMessage(event: "event-2", now: now), now: now), .allowed)
        var otherScope = first; otherScope.scope = "/node/B"; otherScope.sourceID = "route-B"
        XCTAssertEqual(try restarted.receive(otherScope, now: now), .allowed)
        var expired = first; expired.metadata?.expiresAt = now
        XCTAssertEqual(try restarted.receive(expired, now: now), .expired)
    }

    func testIndependentInstancesSerializeConcurrentArrival() throws {
        let url = try XCTUnwrap(store.url)
        let message = completionMessage(event: "concurrent", now: now)
        let now = now
        let results = HubTestBox<[PushDeliveryStore.Disposition]>([])
        let failures = HubTestBox(0)
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            do {
                let disposition = try PushDeliveryStore(url: url).receive(message, now: now)
                results.update { $0.append(disposition) }
            } catch { failures.update { $0 += 1 } }
        }
        XCTAssertEqual(failures.value, 0)
        XCTAssertEqual(results.value.filter { $0 == .allowed }.count, 1)
        XCTAssertEqual(results.value.filter { $0 == .replay }.count, 31)
    }

    func testCapacityDoesNotEvictUnexpiredReplayProtection() throws {
        try store.transaction { state in
            state.events = Dictionary(uniqueKeysWithValues: (0..<PushDeliveryStore.capacity).map {
                ("event-\($0)", now.addingTimeInterval(60))
            })
        }
        XCTAssertEqual(try store.receive(completionMessage(now: now), now: now), .capacity)
        let later = now.addingTimeInterval(61)
        XCTAssertEqual(try store.receive(completionMessage(now: later), now: later), .allowed)
        XCTAssertLessThanOrEqual(try store.transaction { $0.events.count }, PushDeliveryStore.capacity)
    }

    func testExactReadTombstoneWinsDeliveryRaceAndNeverClearsNewer() throws {
        try store.acknowledgeRead(origin: "https://hub.example", scope: "/node/A", store: "store-1", session: "session-1", sequence: 7, now: now)
        let restarted = PushDeliveryStore(url: store.url)
        XCTAssertEqual(try restarted.receive(completionMessage(sequence: 7, now: now), now: now), .read)
        XCTAssertEqual(try restarted.receive(completionMessage(event: "newer", sequence: 8, now: now), now: now), .allowed)
        var otherStore = completionMessage(event: "other-store", now: now)
        otherStore.metadata?.storeInstanceID = "replacement"
        XCTAssertEqual(try restarted.receive(otherStore, now: now), .allowed)
        var manual = completionMessage(event: "manual", now: now); manual.metadata?.kind = "manual"
        XCTAssertEqual(try restarted.receive(manual, now: now), .allowed)
        try restarted.acknowledgeRead(origin: "https://hub.example", scope: "/node/A", store: "store-1", session: "session-1", sequence: 2, now: now)
        XCTAssertTrue(try restarted.hasRead(completionMessage(sequence: 7, now: now), now: now))
    }

    func testDisableIsDurableAcrossUnloadedNodesAndLateEnrollment() throws {
        let origin = "https://hub.example"
        try store.remember(origin: origin, scope: "/node/A", endpoint: "endpoint-A", subscriptionID: "sub-A")
        try store.remember(origin: origin, scope: "/node/B", endpoint: "endpoint-B", subscriptionID: "sub-B")
        try store.setEnabled(false)
        let restarted = PushDeliveryStore(url: store.url)
        XCTAssertEqual(Set(try restarted.pending().compactMap(\.subscriptionID)), ["sub-A", "sub-B"])
        XCTAssertEqual(try restarted.receive(completionMessage(now: now), now: now), .disabled)
        try restarted.remember(origin: origin, scope: "/node/C", endpoint: "late-endpoint", subscriptionID: "late-sub")
        XCTAssertEqual(try restarted.pending().count, 3)
        try restarted.setEnabled(true) // explicit enable does NOT drop cleanup
        XCTAssertEqual(try restarted.pending().count, 3)
        try restarted.acknowledgeCleanup(origin: origin, scope: "/node/B", subscriptionID: "sub-A")
        XCTAssertEqual(try restarted.pending().count, 3, "wrong scope cannot consume a handle")
        try restarted.acknowledgeCleanup(origin: origin, scope: "/node/A", subscriptionID: "sub-A")
        XCTAssertEqual(try restarted.pending().count, 2)
        try restarted.setEnabled(false, origin: origin, scope: "/node/A")
        XCTAssertFalse(try restarted.isEnabled(origin: origin, scope: "/node/A"))
        XCTAssertTrue(try restarted.isEnabled(origin: origin, scope: "/node/B"))
        try restarted.migrate(enabled: true, optOuts: [])
        XCTAssertFalse(try restarted.isEnabled(origin: origin, scope: "/node/A"), "reconcile/migrate never clears off")
    }

    func testCorruptOrUnavailableStorageDoesNotResetReplayAndOffState() throws {
        try Data("corrupt".utf8).write(to: XCTUnwrap(store.url))
        XCTAssertThrowsError(try store.migrate(enabled: true, optOuts: []))
        XCTAssertFalse(store.available)
        XCTAssertFalse(PushDeliveryStore(url: nil).available)
    }
}

final class NotificationMetadataTests: XCTestCase {
    func testV2MetadataSurvivesRealEncryptedNSEContentAndDuplicateIsQuiet() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let deliveries = PushDeliveryStore(url: directory.appendingPathComponent("state.json"))
        try deliveries.migrate(enabled: true, optOuts: [])
        let identities = PushIdentityStore(storage: InMemoryPushStorage())
        let identity = try identities.loadOrCreate()
        try identities.setRoute(tag: "shared-vapid", origin: "https://hub.example", scope: "/node/A", label: "A", nodeBasePath: "/ui")
        try identities.setRoute(tag: "shared-vapid", origin: "https://hub.example", scope: "/node/B", label: "B", nodeBasePath: "/ui")
        let object = completionObject(now: Date())
        let json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let auth = identity.authenticationSecret(tag: "shared-vapid", origin: "https://hub.example", scope: "/node/A")
        let payload = try relayedPayload(json, identity: identity, tag: "shared-vapid", authSecret: auth)
        let content = UNMutableNotificationContent(); content.userInfo = payload; content.sound = .default
        let request = UNNotificationRequest(identifier: "fake-apns-request", content: content, trigger: nil)
        let first = try PushMessage.content(for: request, identities: identities, deliveries: deliveries)
        let decoded = try XCTUnwrap(PushMessage.delivered(userInfo: first.userInfo))
        XCTAssertEqual(decoded.scope, "/node/A")
        XCTAssertEqual(decoded.sourceID, PushIdentity.routeID(tag: "shared-vapid", origin: "https://hub.example", scope: "/node/A"))
        XCTAssertEqual(decoded.url?.absoluteString, "https://hub.example/node/A/chat/session-1")
        XCTAssertEqual(decoded.metadata, try PushMetadata.parse(object))
        XCTAssertNil(first.userInfo["webpush"])
        XCTAssertEqual(first.userInfo[PushMessage.dispositionKey] as? String, "allowed")
        let replay = try PushMessage.content(for: request, identities: identities, deliveries: PushDeliveryStore(url: deliveries.url))
        XCTAssertEqual(replay.userInfo[PushMessage.dispositionKey] as? String, "replay")
        XCTAssertEqual(replay.body, ""); XCTAssertNil(replay.sound)
        // This tests quiet content only, NOT an impossible NSE cancellation.
    }

    func testRejectsUnknownMalformedAndAmbiguousCompletionButPreservesManual() throws {
        XCTAssertNil(try PushMetadata.parse(["title": "hello", "body": "world"]))
        let invalidObjects: [[String: Any]] = [
            ["version": 99, "title": "do not treat as manual"],
            ["kind": "completion", "title": "malformed"],
            ["session_id": "s", "body": "missing envelope"],
            ["version": 2, "kind": "manual", "body": "missing event/expiry"],
            ["version": 1, "body": "malformed completion"],
        ]
        for object in invalidObjects { XCTAssertThrowsError(try PushMetadata.parse(object)) }
        var object = completionObject(now: Date())
        object["attention_seq"] = true
        XCTAssertThrowsError(try PushMetadata.parse(object))
        object["attention_seq"] = 2.5
        XCTAssertThrowsError(try PushMetadata.parse(object))
        object["attention_seq"] = 9_007_199_254_740_992 as NSNumber
        XCTAssertThrowsError(try PushMetadata.parse(object))
        object["kind"] = "manual"
        let manual = try XCTUnwrap(PushMetadata.parse(object))
        XCTAssertNil(manual.windowID); XCTAssertNil(manual.attentionSequence)
        let identity = PushIdentity.generate()
        let json = String(decoding: try JSONSerialization.data(withJSONObject: completionObject(now: Date())), as: UTF8.self)
        let ambiguous = try relayedPayload(json, identity: identity, tag: "unknown")
        XCTAssertThrowsError(try PushMessage.decode(userInfo: ambiguous, identity: identity), "v2 needs authenticated scope")
    }

    func testRFC3339NanoAndLegacyManualBodyPreservation() throws {
        let created = try XCTUnwrap(PushMetadata.date("2026-10-22T12:00:00.123456789Z"))
        let expires = try XCTUnwrap(PushMetadata.date("2026-10-22T13:00:00.123456789Z"))
        XCTAssertEqual(expires.timeIntervalSince(created), 3600, accuracy: 0.001)
        let message = PushMessage.message(from: ["title": "Manual", "body": "\nActual body\n"], origin: nil)
        XCTAssertEqual(message.body, "\nActual body\n")
        XCTAssertNil(message.metadata)
        XCTAssertNotNil(PushMessage.delivered(userInfo: message.userInfo), "legacy decrypted manual needs no invented source")
    }

    func testScopeValidationRejectsTraversalAndOtherNode() {
        for scope in ["//evil", "/node/../B", "/node/%2e%2e/B", "/node/A?x", "/node/A\\B", "/node/A\n"] {
            XCTAssertFalse(NativePushBridge.validScope(scope), scope)
        }
        XCTAssertFalse(NativePushBridge.scope("/node/A", contains: URL(string: "https://hub.example/node/AB/chat/s")!))
        XCTAssertTrue(NativePushBridge.scope("/node/A", contains: URL(string: "https://hub.example/node/A/chat/s")!))
    }
}

@MainActor
final class NativeNotificationLifecycleTests: XCTestCase {
    private var directory: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var deliveries: PushDeliveryStore!
    private var inbox: FakePushInbox!
    private var identities: PushIdentityStore!
    private var center: PushCenter!
    private let origin = "https://hub.example"

    override func setUp() async throws {
        suite = "notification-lifecycle-\(UUID().uuidString)"
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suite)!
        deliveries = PushDeliveryStore(url: directory.appendingPathComponent("state.json"))
        inbox = FakePushInbox()
        identities = PushIdentityStore(storage: InMemoryPushStorage())
        _ = try identities.loadOrCreate()
        try identities.setRoute(tag: "shared", origin: origin, scope: "/node/A")
        try identities.setRoute(tag: "shared", origin: origin, scope: "/node/B")
        center = PushCenter(defaults: defaults, identities: identities,
            authorizer: NotificationTestAuthorizer(), relayTransport: { _ in XCTFail("No relay calls expected"); throw PushError.relayUnavailable },
            registerForRemote: {}, deliveries: deliveries, inbox: inbox)
        center.activateScene = { _, _, _ in }
        center.supportsMultipleScenes = { true }
        center.isActive = { true }
        center.windows.sceneIsActive = { _ in true }
        await center.setEnabled(true)
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: directory)
    }

    func testReadClearsOnlyExactSourceStoreSessionThroughSequence() async throws {
        var newer = completionMessage(event: "newer", sequence: 8)
        var otherScope = completionMessage(event: "other-node"); otherScope.scope = "/node/B"
        var otherStore = completionMessage(event: "other-store"); otherStore.metadata?.storeInstanceID = "store-2"
        var otherSession = completionMessage(event: "other-session"); otherSession.metadata?.sessionID = "session-2"
        var otherOrigin = completionMessage(event: "other-origin"); otherOrigin.origin = "https://elsewhere.example"
        var manual = completionMessage(event: "manual"); manual.metadata?.kind = "manual"
        newer.metadata?.windowID = "other-window" // read is shared, attendance is not
        let messages = [completionMessage(), newer, otherScope, otherStore, otherSession, otherOrigin, manual]
        inbox.items = messages.enumerated().map { request("card-\($0.offset)", $0.element) }
        inbox.pendingItems = inbox.items
        try await center.acknowledgeRead(origin: origin, scope: "/node/A", store: "store-1", session: "session-1", sequence: 7)
        XCTAssertEqual(inbox.removedDelivered, ["card-0"])
        XCTAssertEqual(inbox.removedPending, ["card-0"])
        XCTAssertEqual(try deliveries.receive(completionMessage(event: "late")), .read)
    }

    func testForegroundUsesOnlyOwnerPolicyLeaseAndDurableOptOut() throws {
        let message = completionMessage()
        center.visibleURL = message.url
        XCTAssertEqual(center.presentationOptions(userInfo: message.userInfo), [.banner, .list, .sound], "URL alone is not attendance")
        let now = Date()
        center.windows.bind(windowID: "owner", documentID: "doc", origin: origin)
        XCTAssertTrue(center.windows.update(windowID: "owner", documentID: "doc", origin: origin, sequence: 1,
            active: true, expires: now.addingTimeInterval(30), now: now))
        center.visibleURL = URL(string: origin + "/node/B/chat/other")
        XCTAssertEqual(center.presentationOptions(userInfo: message.userInfo), [], "around owner suppresses across selected conversations without read")
        var otherWindow = message; otherWindow.metadata?.windowID = "sibling"
        XCTAssertEqual(center.presentationOptions(userInfo: otherWindow.userInfo), [.banner, .list, .sound])
        center.windows.release(windowID: "owner")
        XCTAssertEqual(center.presentationOptions(userInfo: message.userInfo), [.banner, .list, .sound])
        center.disable(origin: origin, scope: "/node/A")
        XCTAssertEqual(center.presentationOptions(userInfo: message.userInfo), [])
        XCTAssertFalse(try PushDeliveryStore(url: deliveries.url).isEnabled(origin: origin, scope: "/node/A"))
    }

    func testHiddenChatCannotRenewPresenceOrAcknowledgeAttention() async throws {
        let documentURL = URL(string: origin + "/node/A/chat/session-1")!
        center.windows.bind(windowID: "owner", documentID: "doc", origin: origin)
        func presence(_ sequence: Int, visible: Bool) async -> Result<Any, NativePushBridge.BridgeError> {
            await NativePushBridge.handle(body: [
                "method": "notificationPresence", "scope": "/node/A", "document_id": "doc",
                "payload": ["version": 2, "source": "/node/A", "window_id": "owner", "document_id": "doc",
                            "sequence": sequence, "active": true,
                            "expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(30))]
            ], frameOrigin: origin, isMainFrame: true, expectedOrigin: origin, center: center,
               windowID: "owner", documentID: "doc", documentURL: documentURL, isContentVisible: visible)
        }
        _ = try await presence(1, visible: true).get()
        XCTAssertTrue(center.windows.isAround(windowID: "owner", origin: origin))
        _ = try await presence(2, visible: false).get()
        XCTAssertFalse(center.windows.isAround(windowID: "owner", origin: origin), "A hidden page's active heartbeat must stay inactive")
        _ = try await presence(3, visible: false).get()
        XCTAssertFalse(center.windows.isAround(windowID: "owner", origin: origin))
        let read = await NativePushBridge.handle(body: [
            "method": "notificationRead", "scope": "/node/A", "document_id": "doc",
            "payload": ["version": 2, "source": "/node/A", "store_instance_id": "store-1",
                        "session_id": "session-1", "attention_seq": 7]
        ], frameOrigin: origin, isMainFrame: true, expectedOrigin: origin, center: center,
           windowID: "owner", documentID: "doc", documentURL: documentURL, isContentVisible: false)
        XCTAssertThrowsError(try read.get())
        XCTAssertFalse(try deliveries.hasRead(completionMessage()))
        _ = try await presence(4, visible: true).get()
        XCTAssertTrue(center.windows.isAround(windowID: "owner", origin: origin), "Returning to chat can renew an actual foreground lease")
    }

    func testPresenceRejectsStaleDocumentSequenceExpiryAndSleep() {
        let windows = center.windows
        let now = Date()
        windows.bind(windowID: "owner", documentID: "old", origin: origin)
        XCTAssertTrue(windows.update(windowID: "owner", documentID: "old", origin: origin, sequence: 2, active: true,
            expires: now.addingTimeInterval(30), now: now, uptime: 100))
        XCTAssertFalse(windows.update(windowID: "owner", documentID: "old", origin: origin, sequence: 1, active: false,
            expires: now.addingTimeInterval(30), now: now, uptime: 100))
        XCTAssertFalse(windows.isAround(windowID: "owner", origin: origin, now: now, uptime: 131), "monotonic bound wins clock rollback/sleep")
        windows.bind(windowID: "owner", documentID: "new", origin: origin)
        XCTAssertFalse(windows.update(windowID: "owner", documentID: "old", origin: origin, sequence: 999, active: true,
            expires: now.addingTimeInterval(30), now: now, uptime: 100))
        XCTAssertFalse(windows.update(windowID: "owner", documentID: "new", origin: origin, sequence: 1, active: true,
            expires: now.addingTimeInterval(66), now: now, uptime: 100))
        XCTAssertFalse(windows.update(windowID: "owner", documentID: "new", origin: origin, sequence: 1, active: true,
            expires: now, now: now, uptime: 100))
    }

    func testBridgeCapabilitiesReadCleanupAndFrameScopeValidation() async throws {
        func call(_ method: String, scope: String = "/node/A", payload: [String: Any] = [:], frameOrigin: String? = nil,
                  main: Bool = true, document: String? = "doc", url: String = "https://hub.example/node/A/chat/session-1") async -> Result<Any, NativePushBridge.BridgeError> {
            await NativePushBridge.handle(body: ["method": method, "scope": scope, "window_id": "owner", "document_id": "doc", "payload": payload],
                frameOrigin: frameOrigin ?? origin, isMainFrame: main, expectedOrigin: origin, center: center,
                windowID: "owner", documentID: document, documentURL: URL(string: url))
        }
        let caps = await call("notificationCapabilities", scope: "")
        let value = try caps.get() as? [String: Any]
        XCTAssertEqual(value?["version"] as? Int, 2)
        XCTAssertEqual(value?["document_id"] as? String, "doc")
        for result in [await call("notificationCapabilities", frameOrigin: "https://evil.example"),
                       await call("notificationCapabilities", main: false),
                       await call("notificationCapabilities", document: nil),
                       await call("notificationPendingCleanup", scope: "/node/B", payload: ["source": "/node/B"])] {
            XCTAssertThrowsError(try result.get())
        }
        let broadened = await call("notificationPendingCleanup", scope: "", payload: ["source": ""])
        XCTAssertThrowsError(try broadened.get(), "node page cannot claim a known Hub parent scope")
        try deliveries.remember(origin: origin, scope: "/node/A", endpoint: "endpoint")
        let enrollment = await call("notificationEnrollment", payload: ["source": "/node/A", "subscription_id": "sub-1"])
        _ = try enrollment.get()
        let verifiedAgain = await call("notificationEnrollment", payload: ["source": "/node/A", "subscription_id": "sub-1"])
        _ = try verifiedAgain.get()
        XCTAssertEqual(try deliveries.transaction { $0.enrollments.count }, 1, "verified cached enrollment is idempotent")
        center.disable(origin: origin, scope: "/node/A")
        let pending = await call("notificationPendingCleanup", payload: ["source": "/node/A"])
        XCTAssertEqual(try pending.get() as? [[String: String]], [["subscription_id": "sub-1"]])
        let ack = await call("notificationCleanupAcknowledged", payload: ["source": "/node/A", "subscription_id": "sub-1"])
        _ = try ack.get()
        XCTAssertEqual(try deliveries.pending().count, 0)
        let read = await call("notificationRead", payload: ["version": 2, "source": "/node/A", "store_instance_id": "store-1", "session_id": "session-1", "attention_seq": 7])
        _ = try read.get()
        XCTAssertTrue(try deliveries.hasRead(completionMessage()))
        let crossScope = await call("notificationRead", payload: ["version": 2, "source": "/node/B", "store_instance_id": "store-1", "session_id": "session-1", "attention_seq": 99])
        XCTAssertThrowsError(try crossScope.get())
    }

    func testMissingSharedContainerNeverAdvertisesV2() async {
        let unsupported = PushCenter(defaults: defaults, identities: PushIdentityStore(storage: InMemoryPushStorage()),
            authorizer: NotificationTestAuthorizer(), registerForRemote: {}, deliveries: PushDeliveryStore(url: nil), inbox: inbox)
        let result = await NativePushBridge.handle(body: ["method": "notificationCapabilities", "scope": "", "window_id": "owner", "document_id": "doc"],
            frameOrigin: origin, isMainFrame: true, expectedOrigin: origin, center: unsupported,
            windowID: "owner", documentID: "doc", documentURL: URL(string: origin))
        XCTAssertThrowsError(try result.get())
    }

    func testOwnerGoneRequiresExplicitFreshSceneClaimAndTapIsNotRead() throws {
        let target = completionMessage()
        var activity: NSUserActivity?
        center.activateScene = { session, value, _ in XCTAssertNil(session); activity = value }
        center.windows.keyWindowOverride = { "sibling" }
        center.open(urlString: target.url?.absoluteString, configuredServer: URL(string: origin), windowID: "closed-owner")
        let navigation = try XCTUnwrap(center.pendingNavigation)
        XCTAssertNil(navigation.windowID, "no arbitrary sibling owner")
        XCTAssertFalse(try deliveries.hasRead(target), "taps/opening are not ACKs")
        let wrong = NSUserActivity(activityType: PushCenter.navigationActivity)
        wrong.userInfo = ["navigation_id": UUID().uuidString]
        center.claimNavigation(wrong, windowID: "sibling")
        XCTAssertNil(center.pendingNavigation?.windowID)
        center.claimNavigation(try XCTUnwrap(activity), windowID: "fresh-window")
        XCTAssertEqual(center.pendingNavigation?.windowID, "fresh-window")
        center.claimNavigation(try XCTUnwrap(activity), windowID: "sibling")
        XCTAssertEqual(center.pendingNavigation?.windowID, "fresh-window", "a claimed tap cannot be stolen")
    }
}

final class FakePushInbox: PushNotificationInbox, @unchecked Sendable { // only used from serial test code
    var items: [UNNotificationRequest] = []
    var pendingItems: [UNNotificationRequest] = []
    var removedDelivered: [String] = []
    var removedPending: [String] = []
    func delivered() async -> [UNNotificationRequest] { items }
    func pending() async -> [UNNotificationRequest] { pendingItems }
    func removeDelivered(_ ids: [String]) { removedDelivered += ids }
    func removePending(_ ids: [String]) { removedPending += ids }
}

private struct NotificationTestAuthorizer: PushAuthorizer {
    func status() async -> UNAuthorizationStatus { .authorized }
    func request() async throws -> Bool { true }
}

private func completionObject(event: String = "event-1", sequence: Int64 = 7, now: Date) -> [String: Any] {
    let formatter = ISO8601DateFormatter()
    return ["version": 2, "kind": "completion", "event_id": event, "turn_id": "turn-1", "response_id": "response-1",
            "window_id": "owner", "store_instance_id": "store-1", "session_id": "session-1", "attention_seq": sequence,
            "run_epoch": 1, "outcome": "completed", "source": "/node/A", "title": "Response complete", "body": "Ready",
            "url": "/ui/chat/session-1", "created_at": formatter.string(from: now),
            "expires_at": formatter.string(from: now.addingTimeInterval(3600))]
}

private func completionMessage(event: String = "event-1", sequence: Int64 = 7, now: Date = Date()) -> PushMessage {
    PushMessage.message(from: completionObject(event: event, sequence: sequence, now: now),
        origin: "https://hub.example", scope: "/node/A", nodeBasePath: "/ui", sourceID: "route-A")
}

private func request(_ identifier: String, _ message: PushMessage) -> UNNotificationRequest {
    let content = UNMutableNotificationContent(); content.userInfo = message.userInfo
    return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
}

// MARK: - Exact actual-core-producer export bytes (test bundle resources)

final class ActualProducerFixtureTests: XCTestCase {
    private let origin = "https://producer-fixture.example"

    func testActualProducerDecoderMetadataAndCompactAgreement() throws {
        let fixtures = try loadProducerFixtures()
        var messages: [String: PushMessage] = [:]
        for fixture in fixtures {
            let message = try decodeProducerFixture(fixture)
            let metadata = try XCTUnwrap(message.metadata)
            XCTAssertEqual(metadata.version, 2)
            XCTAssertEqual(metadata.kind, fixture.entry.kind)
            XCTAssertEqual(metadata.eventID, fixture.object["event_id"] as? String)
            XCTAssertEqual(metadata.source, fixture.entry.source)
            XCTAssertEqual(metadata.createdAt, (fixture.object["created_at"] as? String).flatMap(PushMetadata.date))
            XCTAssertEqual(metadata.expiresAt, (fixture.object["expires_at"] as? String).flatMap(PushMetadata.date))
            XCTAssertEqual(message.title, fixture.object["title"] as? String)
            XCTAssertEqual(message.body, fixture.object["body"] as? String)
            XCTAssertEqual(message.url?.absoluteString, origin + (fixture.object["url"] as? String ?? ""))
            XCTAssertEqual(message.scope, fixture.entry.source)
            XCTAssertEqual(message.sourceID, PushIdentity.routeID(tag: "producer", origin: origin, scope: fixture.entry.source))
            XCTAssertEqual(PushMessage.delivered(userInfo: message.userInfo)?.metadata, metadata,
                           "exact event/read identity survives delivered metadata encoding")
            if metadata.kind == "completion" {
                XCTAssertEqual(metadata.turnID, fixture.object["turn_id"] as? String)
                XCTAssertEqual(metadata.responseID, fixture.object["response_id"] as? String)
                XCTAssertEqual(metadata.windowID, fixture.object["window_id"] as? String)
                XCTAssertEqual(metadata.storeInstanceID, fixture.object["store_instance_id"] as? String)
                XCTAssertEqual(metadata.sessionID, fixture.object["session_id"] as? String)
                XCTAssertEqual(metadata.attentionSequence, PushMetadata.sequence(fixture.object["attention_seq"]))
                XCTAssertEqual(metadata.runEpoch, PushMetadata.sequence(fixture.object["run_epoch"]))
                XCTAssertEqual(metadata.outcome, fixture.object["outcome"] as? String)
            } else {
                XCTAssertNil(metadata.windowID); XCTAssertNil(metadata.turnID)
                XCTAssertNil(metadata.storeInstanceID); XCTAssertNil(metadata.attentionSequence)
                XCTAssertEqual(message.body, "Build finished: all tests passed. 节点 😀 <&>\nNext step.")
            }
            messages[fixture.entry.file] = message
        }
        let primary = try XCTUnwrap(messages["completion.json"])
        let compact = try XCTUnwrap(messages["completion-compact.json"])
        XCTAssertEqual(primary.metadata, compact.metadata, "compact retry retains every ownership/read/replay field")
        XCTAssertEqual(primary.url, compact.url)
        // Metadata is compared structurally above; JSON object key order is not stable.
        XCTAssertEqual(primary.userInfo.filter { $0.key != PushMetadata.key },
                       compact.userInfo.filter { $0.key != PushMetadata.key },
                       "compact retry retains every non-metadata delivery routing field")
        XCTAssertNotEqual(primary.title, compact.title, "actual compact retry shortened display title only")
    }

    func testActualProducerReplayExpiryAndReadUseManifestClockNotWallClock() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtures = try loadProducerFixtures()
        for fixture in fixtures {
            let message = try decodeProducerFixture(fixture)
            let metadata = try XCTUnwrap(message.metadata)
            let created = try XCTUnwrap(metadata.createdAt)
            let expires = try XCTUnwrap(metadata.expiresAt)
            let now = try XCTUnwrap(PushMetadata.date(fixture.entry.injectedTestNow))
            XCTAssertGreaterThan(now, created); XCTAssertLessThan(now, expires)
            XCTAssertEqual(expires.timeIntervalSince(created), metadata.kind == "manual" ? 60 : 86400, accuracy: 0.001)
            let store = PushDeliveryStore(url: directory.appendingPathComponent(fixture.entry.file))
            try store.migrate(enabled: true, optOuts: [])
            // These historic exports must NEVER be timestamp-rewritten or tested
            // against Date(). The manual CLI producer's real lifetime is 60s.
            XCTAssertEqual(try store.receive(message, now: now), .allowed)
            XCTAssertEqual(try PushDeliveryStore(url: store.url).receive(message, now: now), .replay)
            XCTAssertEqual(try store.receive(message, now: expires), .expired)
            if metadata.kind == "completion" {
                try store.acknowledgeRead(origin: origin, scope: fixture.entry.source,
                    store: XCTUnwrap(metadata.storeInstanceID), session: XCTUnwrap(metadata.sessionID),
                    sequence: XCTUnwrap(metadata.attentionSequence), now: now)
                XCTAssertEqual(try store.receive(message, now: now), .read)
            }
        }
        let primary = try XCTUnwrap(fixtures.first { $0.entry.file == "completion.json" })
        let compact = try XCTUnwrap(fixtures.first { $0.entry.file == "completion-compact.json" })
        let now = try XCTUnwrap(PushMetadata.date(primary.entry.injectedTestNow))
        let shared = PushDeliveryStore(url: directory.appendingPathComponent("same-event.json"))
        try shared.migrate(enabled: true, optOuts: [])
        XCTAssertEqual(try shared.receive(decodeProducerFixture(primary), now: now), .allowed)
        XCTAssertEqual(try shared.receive(decodeProducerFixture(compact), now: now), .replay,
                       "compact wire retry cannot mint another native event")
    }

    func testActualProducerStrictHorizonAndVariableFractionParsing() throws {
        let fixture = try XCTUnwrap(loadProducerFixtures().first { $0.entry.file == "completion.json" })
        XCTAssertNotNil(try PushMetadata.parse(fixture.object), "unaltered actual 24h producer export must decode")
        // Derived boundary cases are not replacements for the checked-in bytes.
        // No +1s tolerance: the review's floating-point rejection claim was retracted.
        for fraction in ["1", "12", "123", "123456789"] {
            var object = fixture.object
            object["created_at"] = "2026-10-22T11:19:03.\(fraction)Z"
            object["expires_at"] = "2026-10-23T11:19:03.\(fraction)Z"
            let metadata = try XCTUnwrap(PushMetadata.parse(object))
            XCTAssertEqual(try XCTUnwrap(metadata.expiresAt).timeIntervalSince(XCTUnwrap(metadata.createdAt)), 86400)
        }
        var boundary = fixture.object
        boundary["run_epoch"] = 0
        XCTAssertThrowsError(try PushMetadata.parse(boundary), "new completion epochs are strictly positive, matching public receiver")
        boundary.removeValue(forKey: "run_epoch")
        XCTAssertThrowsError(try PushMetadata.parse(boundary), "missing completion epoch remains fail-closed")
        boundary = fixture.object
        boundary["created_at"] = "2026-10-22T11:19:03.000Z"
        boundary["expires_at"] = "2026-10-23T11:19:03.001Z"
        XCTAssertThrowsError(try PushMetadata.parse(boundary), "24h +1ms remains invalid")
        boundary["expires_at"] = boundary["created_at"]
        XCTAssertThrowsError(try PushMetadata.parse(boundary), "zero lifetime remains invalid")
    }

    private func loadProducerFixtures() throws -> [ProducerFixture] {
        let bundle = Bundle(for: ActualProducerFixtureTests.self)
        let root = try XCTUnwrap(bundle.url(forResource: "ProducerFixtures", withExtension: nil))
        let manifest = try JSONDecoder().decode(ProducerFixtureManifest.self,
                                               from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.publicReviewSHA, "600d7199e30375758fefba7a0e57a4ae72f9a923")
        XCTAssertEqual(manifest.implementationSHA, "7f8b8251d0370fe7f475925b50ad7f46a8a697a2")
        XCTAssertTrue(manifest.syntheticOnly); XCTAssertTrue(manifest.unmodifiedProducerBytes)
        XCTAssertEqual(Set(manifest.fixtures.map(\.file)), ["completion.json", "completion-compact.json", "manual.json"])
        return try manifest.fixtures.map { entry in
            let bytes = try Data(contentsOf: root.appendingPathComponent(entry.file))
            XCTAssertEqual(bytes.count, entry.bytes)
            XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), entry.sha256)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            return ProducerFixture(entry: entry, bytes: bytes, object: object)
        }
    }

    private func decodeProducerFixture(_ fixture: ProducerFixture) throws -> PushMessage {
        let identities = PushIdentityStore(storage: InMemoryPushStorage())
        let identity = try identities.loadOrCreate()
        try identities.setRoute(tag: "producer", origin: origin, scope: fixture.entry.source)
        let auth = identity.authenticationSecret(tag: "producer", origin: origin, scope: fixture.entry.source)
        // Encrypt the exact Data export, not a parsed/remarshaled lookalike.
        let ciphertext = try encryptWebPush(fixture.bytes, identity: identity, authSecret: auth)
        let payload: [AnyHashable: Any] = ["webpush": ["v": 1, "ce": "aes128gcm", "k": "producer", "body": ciphertext.base64EncodedString()]]
        return try PushMessage.decode(userInfo: payload, identity: identities.load())
    }
}

private struct ProducerFixtureManifest: Decodable {
    let publicReviewSHA: String
    let implementationSHA: String
    let syntheticOnly: Bool
    let unmodifiedProducerBytes: Bool
    let fixtures: [Entry]
    enum CodingKeys: String, CodingKey {
        case publicReviewSHA = "public_review_sha", implementationSHA = "production_implementation_sha"
        case syntheticOnly = "synthetic_only", unmodifiedProducerBytes = "unmodified_producer_bytes", fixtures
    }
    struct Entry: Decodable {
        let file: String
        let sha256: String
        let bytes: Int
        let kind: String
        let source: String
        let injectedTestNow: String
        enum CodingKeys: String, CodingKey {
            case file, sha256, bytes, kind, source
            case injectedTestNow = "injected_test_now"
        }
    }
}

private struct ProducerFixture {
    let entry: ProducerFixtureManifest.Entry
    let bytes: Data
    let object: [String: Any]
}
