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
        let lock = NSLock()
        var results: [PushDeliveryStore.Disposition] = []
        var failures = 0
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            do {
                let disposition = try PushDeliveryStore(url: url).receive(message, now: now)
                lock.withLock { results.append(disposition) }
            } catch { lock.withLock { failures += 1 } }
        }
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(results.filter { $0 == .allowed }.count, 1)
        XCTAssertEqual(results.filter { $0 == .replay }.count, 31)
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
        center.activateScene = { _, _ in }
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
        center.activateScene = { session, value in XCTAssertNil(session); activity = value }
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

final class FakePushInbox: PushNotificationInbox {
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
