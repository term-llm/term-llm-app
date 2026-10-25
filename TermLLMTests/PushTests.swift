import CryptoKit
import UserNotifications
import WebKit
import XCTest
@testable import TermLLM

// MARK: - Web Push decryption (shared with the Notification Service Extension)

final class WebPushCryptoTests: XCTestCase {
    private func b64(_ s: String) -> Data { Data(base64URLEncoded: s.replacingOccurrences(of: " ", with: ""))! }

    /// RFC 8291 Appendix A.
    func testDecryptsRFC8291Example() throws {
        let uaPrivate = try P256.KeyAgreement.PrivateKey(rawRepresentation: b64("q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94"))
        XCTAssertEqual(uaPrivate.publicKey.x963Representation,
                       b64("BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"))
        let header = b64("DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z 9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml mlMoZIIgDll6e3vCYLocInmYWAmS6Tlz AC8wEqKK6PBru3jl7A8")
        let ciphertext = b64("8pfeW0KbunFT06SuDKoJH9Ql87S1QUrd irN6GcG7sFz1y1sqLgVi1VhjVkHsUoEs bI_0LpXMuGvnzQ")
        XCTAssertEqual(header.count, 86)
        let plaintext = try WebPushCrypto.decrypt(header + ciphertext, privateKey: uaPrivate,
                                                  authSecret: b64("BTBZMqHH6r4Tts7J_aSIgg"))
        XCTAssertEqual(String(decoding: plaintext, as: UTF8.self), "When I grow up, I want to be a watermelon")
    }

    func testRejectsTamperedAndMalformedMessages() throws {
        let identity = PushIdentity.generate()
        let body = try encryptWebPush(Data("hello".utf8), identity: identity)
        var tampered = body
        tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try WebPushCrypto.decrypt(tampered, privateKey: identity.agreementKey(), authSecret: identity.authSecret)) {
            XCTAssertEqual($0 as? WebPushCrypto.Failure, .decryptionFailed)
        }
        XCTAssertThrowsError(try WebPushCrypto.decrypt(body.prefix(40), privateKey: identity.agreementKey(), authSecret: identity.authSecret))
        XCTAssertThrowsError(try WebPushCrypto.decrypt(body, privateKey: identity.agreementKey(), authSecret: Data(count: 16)))
        XCTAssertEqual(try WebPushCrypto.decrypt(body, privateKey: identity.agreementKey(), authSecret: identity.authSecret),
                       Data("hello".utf8))
    }

    /// Must match push-relay's TestSourceTagVector.
    func testSourceTagMatchesRelay() {
        let key = b64("BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4")
        XCTAssertEqual(WebPushCrypto.sourceTag(applicationServerKey: key), "Kn8g3g7yY94")
    }

    func testBase64URLRoundTrip() {
        let data = Data([0xfb, 0xff, 0xfe, 0x00, 0x01])
        XCTAssertEqual(data.base64URLEncodedString(), "-__-AAE")
        XCTAssertEqual(Data(base64URLEncoded: "-__-AAE"), data)
        XCTAssertEqual(Data(base64URLEncoded: "-__-AAE="), data)
    }
}

// MARK: - Relayed APNs payload → notification content

final class PushMessageTests: XCTestCase {
    func testDecodesCompletionPushAndRoutesToRegisteredOrigin() throws {
        var identity = PushIdentity.generate()
        identity.routes["tag1"] = "https://hub.example"
        let json = #"{"version":1,"event_id":"completion:r1:s1","session_id":"abc","outcome":"completed","title":"artist: Response complete","body":"Your term-llm response is ready.","url":"/node/artist/chat/abc"}"#
        let userInfo = try relayedPayload(json, identity: identity, tag: "tag1")

        let message = try PushMessage.decode(userInfo: userInfo, identity: identity)
        XCTAssertEqual(message.title, "artist: Response complete")
        XCTAssertEqual(message.body, "Your term-llm response is ready.")
        XCTAssertEqual(message.url?.absoluteString, "https://hub.example/node/artist/chat/abc")
        XCTAssertEqual(message.threadIdentifier, "https://hub.example#abc")
        XCTAssertEqual(message.userInfo[PushMessage.urlKey], "https://hub.example/node/artist/chat/abc")
    }

    func testNotifyBroadcastWithoutURL() throws {
        let identity = PushIdentity.generate()
        let userInfo = try relayedPayload(#"{"title":"term-llm","body":"Deploy finished"}"#, identity: identity, tag: "unknown")
        let message = try PushMessage.decode(userInfo: userInfo, identity: identity)
        XCTAssertEqual(message.body, "Deploy finished")
        XCTAssertNil(message.url, "unregistered source: never trust a URL")
        XCTAssertNil(message.origin)
    }

    func testNotifyUsesEnrolledAgentScopeAndLabel() throws {
        let storage = InMemoryPushStorage()
        let store = PushIdentityStore(storage: storage)
        let identity = try store.loadOrCreate()
        try store.setRoute(tag: "dev", origin: "https://hub.example", scope: "/hub/nodes/Dev", label: "Dev")
        try store.setRoute(tag: "hub", origin: "https://hub.example", scope: "/hub", label: "Hub")
        let payload = try relayedPayload(#"{"title":"term-llm","body":"hello"}"#, identity: identity, tag: "dev")
        let message = try PushMessage.decode(userInfo: payload, identity: store.load())
        XCTAssertEqual(message.title, "Dev")
        XCTAssertEqual(message.body, "hello")
        XCTAssertEqual(message.url?.absoluteString, "https://hub.example/hub/nodes/Dev/")
        XCTAssertEqual(message.userInfo[PushMessage.urlKey], message.url?.absoluteString)
    }

    func testAgentFormattingPreservesChatDestinationAndAvoidsDuplicatePrefix() {
        for (title, expected) in [("Response complete", "Dev: Response complete"),
                                  ("Dev: Response complete", "Dev: Response complete"),
                                  ("dev: Response failed", "dev: Response failed")] {
            let message = PushMessage.message(from: ["title": title, "url": "/hub/nodes/Dev/chat/s1"],
                                              origin: "https://hub.example", scope: "/hub/nodes/Dev", label: "Dev")
            XCTAssertEqual(message.title, expected)
            XCTAssertEqual(message.url?.absoluteString, "https://hub.example/hub/nodes/Dev/chat/s1")
        }
        let rejected = PushMessage.message(from: ["url": "https://evil.example/"], origin: "https://hub.example",
                                           scope: "/hub/nodes/Dev", label: "Dev")
        XCTAssertNil(rejected.url, "an explicitly invalid URL must not become a fallback navigation")
    }

    func testCompletionRebasesBackendPathOntoPublicAgentMount() throws {
        var identity = PushIdentity.generate()
        identity.routes["dev"] = "https://hub.example"
        identity.routeDetails = ["dev": .init(scope: "/hub/node/Dev", label: "Dev", nodeBasePath: "/ui")]
        for path in ["/ui/chat/s1", "/hub/node/Dev/chat/s1"] {
            let payload = try relayedPayload("{\"title\":\"Dev: Response complete\",\"url\":\"\(path)\"}",
                                             identity: identity, tag: "dev")
            let message = try PushMessage.decode(userInfo: payload, identity: identity)
            XCTAssertEqual(message.url?.absoluteString, "https://hub.example/hub/node/Dev/chat/s1")
            XCTAssertEqual(message.title, "Dev: Response complete")
        }
        let rootNode = PushMessage.message(from: ["url": "/chat/s1?view=full"], origin: "https://hub.example",
                                          scope: "/node/Dev", nodeBasePath: "")
        XCTAssertEqual(rootNode.url?.absoluteString, "https://hub.example/node/Dev/chat/s1?view=full")
        let unrelated = PushMessage.message(from: ["url": "/uiverse/chat/s1"], origin: "https://hub.example",
                                           scope: "/node/Dev", nodeBasePath: "/ui")
        XCTAssertEqual(unrelated.url?.path, "/uiverse/chat/s1", "match whole path segments only")
    }

    func testLegacyIdentityWithoutRouteDetailsStillDecodes() throws {
        let identity = PushIdentity.generate()
        let data = try JSONEncoder().encode(identity)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["routeDetails"])
        XCTAssertEqual(try JSONDecoder().decode(PushIdentity.self, from: data), identity)
        let message = PushMessage.message(from: ["title": "term-llm", "body": "hello"], origin: "https://hub.example")
        XCTAssertNil(message.url, "old records must not guess which agent sent the push")
        XCTAssertEqual(message.title, "term-llm")
    }

    func testFailuresKeepPlaceholder() throws {
        let identity = PushIdentity.generate()
        XCTAssertThrowsError(try PushMessage.decode(userInfo: ["aps": [:]], identity: identity)) {
            XCTAssertEqual($0 as? PushMessage.Failure, .notWebPush)
        }
        let payload = try relayedPayload(#"{"title":"x"}"#, identity: identity, tag: "t")
        XCTAssertThrowsError(try PushMessage.decode(userInfo: payload, identity: nil)) {
            XCTAssertEqual($0 as? PushMessage.Failure, .noIdentity)
        }
        XCTAssertThrowsError(try PushMessage.decode(userInfo: payload, identity: .generate()))
        let notJSON = try relayedPayload("plain text", identity: identity, tag: "t")
        XCTAssertThrowsError(try PushMessage.decode(userInfo: notJSON, identity: identity)) {
            XCTAssertEqual($0 as? PushMessage.Failure, .invalidMessage)
        }
    }

    func testURLResolutionStaysOnOrigin() {
        let origin = "https://hub.example"
        XCTAssertEqual(PushMessage.resolve(path: "/ui/chat/1", origin: origin)?.absoluteString, "https://hub.example/ui/chat/1")
        XCTAssertNil(PushMessage.resolve(path: "https://evil.example/x", origin: origin))
        XCTAssertNil(PushMessage.resolve(path: "//evil.example/x", origin: origin))
        XCTAssertNil(PushMessage.resolve(path: "ui/chat/1", origin: origin))
        XCTAssertNil(PushMessage.resolve(path: "/ui/chat/1", origin: nil))
        XCTAssertEqual(PushMessage.resolve(path: "/ui/", origin: "http://localhost:8080")?.absoluteString, "http://localhost:8080/ui/")
    }

    func testIdentityStorePersistsAndRoutes() throws {
        let storage = InMemoryPushStorage()
        let store = PushIdentityStore(storage: storage)
        XCTAssertNil(try store.load())
        let identity = try store.loadOrCreate()
        XCTAssertEqual(try store.loadOrCreate(), identity, "created once")
        XCTAssertEqual(identity.authSecret.count, 16)
        XCTAssertEqual(try identity.agreementKey().publicKey.x963Representation.count, 65)
        try store.setRoute(tag: "t", origin: "https://a.example")
        XCTAssertEqual(try store.load()?.routes, ["t": "https://a.example"])
    }
}

// MARK: - App-wide push state and the web bridge

@MainActor
final class PushCenterTests: XCTestCase {
    private let origin = "https://hub.example"
    private var defaults: UserDefaults!
    private var suite: String!
    private var temporaryDirectory: URL!
    private var deliveries: PushDeliveryStore!
    private var authorizer: FakeAuthorizer!
    private var badgeSink: FakeBadgeSink!
    private var storage: InMemoryPushStorage!
    private var relayRequests: [URLRequest] = []
    private var relayResponse: (Int, String) = (200, #"{"endpoint":"https://relay.example/v1/push/TOKEN"}"#)
    private var registrations = 0
    private var relayBeforeReply: (() async -> Void)?
    private var token = Data([0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89])

    override func setUp() async throws {
        suite = "push-tests-\(UUID().uuidString)"
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        deliveries = PushDeliveryStore(url: temporaryDirectory.appendingPathComponent("state.json"))
        defaults = UserDefaults(suiteName: suite)
        defaults.set("https://relay.example", forKey: PushCenter.relayOverrideKey)
        authorizer = FakeAuthorizer()
        badgeSink = FakeBadgeSink()
        storage = InMemoryPushStorage()
        relayRequests = []
        registrations = 0
        relayBeforeReply = nil
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: temporaryDirectory)
    }

    private func makeCenter(deliverToken: Bool = true, timeout: Duration = .seconds(5)) -> PushCenter {
        var centerRef: PushCenter?
        let center = PushCenter(
            defaults: defaults, identities: PushIdentityStore(storage: storage), authorizer: authorizer,
            relayTransport: { @MainActor [unowned self] request in
                relayRequests.append(request)
                await relayBeforeReply?()
                let response = HTTPURLResponse(url: request.url!, statusCode: relayResponse.0, httpVersion: nil, headerFields: nil)!
                return (Data(relayResponse.1.utf8), response)
            },
            registerForRemote: { [unowned self] in
                registrations += 1
                guard deliverToken else { return }
                let token = token
                Task { @MainActor in centerRef?.didRegister(deviceToken: token) }
            },
            environment: .development, tokenTimeout: timeout, deliveries: deliveries, inbox: FakePushInbox(),
            badgeSetter: { [badgeSink = badgeSink!] count in try await badgeSink.set(count) })
        centerRef = center
        center.isActive = { true }
        center.activateScene = { _, _, _ in }
        return center
    }

    private let serverKey = P256.Signing.PrivateKey().publicKey.x963Representation.base64URLEncodedString()

    func testAttentionBadgeWritesAuthorizedPositiveAndVerifiedZero() async {
        let center = makeCenter()
        await center.setEnabled(true)
        center.updateAttentionBadge(count: 12)
        await waitForBadge { self.badgeSink.badge == 12 }
        center.updateAttentionBadge(count: 0)
        await waitForBadge { self.badgeSink.badge == 0 }
        XCTAssertEqual(badgeSink.attempts, [12, 0])
        XCTAssertNil(center.badgeIssue)
    }

    func testAttentionBadgeSupportsProvisionalAndEphemeralWithoutRequestingPermission() async {
        let center = makeCenter()
        authorizer.current = .provisional
        await center.setEnabled(true)
        center.updateAttentionBadge(count: 3)
        await waitForBadge { self.badgeSink.badge == 3 }
        authorizer.current = .ephemeral
        await center.refreshAuthorization()
        center.updateAttentionBadge(count: 4)
        await waitForBadge { self.badgeSink.badge == 4 }
        XCTAssertEqual(badgeSink.attempts, [3, 4])
        XCTAssertEqual(authorizer.requests, 0)
    }

    func testAttentionBadgeOffAndDeniedNeverWritePositive() async {
        let center = makeCenter()
        center.updateAttentionBadge(count: 8)
        await waitForBadge { self.badgeSink.badge == 0 }
        authorizer.current = .denied
        await center.setEnabled(true)
        center.updateAttentionBadge(count: 9)
        await center.refreshAuthorization()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(badgeSink.attempts, [0])
        XCTAssertEqual(authorizer.requests, 0)

        authorizer.current = .authorized
        await center.refreshAuthorization()
        await waitForBadge { self.badgeSink.badge == 9 }
        authorizer.current = .denied
        await center.refreshAuthorization()
        await waitForBadge { self.badgeSink.badge == 0 }
        XCTAssertEqual(badgeSink.attempts, [0, 9, 0])
    }

    func testAttentionBadgeUnknownInitialTotalLeavesExistingBadgeAlone() async {
        let center = makeCenter()
        center.updateAttentionBadge(count: nil)
        await center.refreshAuthorization()
        await center.setEnabled(true)
        center.updateAttentionBadge(count: nil)
        await center.refreshAuthorization()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(badgeSink.badge, 99)
        XCTAssertTrue(badgeSink.attempts.isEmpty)
        XCTAssertEqual(authorizer.requests, 1, "only the explicit Enable requests permission")

        center.updateAttentionBadge(count: 5)
        await waitForBadge { self.badgeSink.badge == 5 }
        center.updateAttentionBadge(count: nil)
        await center.refreshAuthorization()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(badgeSink.attempts, [5], "temporary unknown totals preserve the verified badge")
    }

    func testAttentionBadgeExplicitOffClearsWithoutAnySuppliedCount() async {
        let center = makeCenter()
        await center.setEnabled(false)
        await waitForBadge { self.badgeSink.badge == 0 }
        XCTAssertEqual(badgeSink.attempts, [0])
        XCTAssertEqual(authorizer.requests, 0)
    }

    func testAttentionBadgeCoalescesDuplicatesAndIntermediateCounts() async {
        let center = makeCenter()
        await center.setEnabled(true)
        badgeSink.pauseNextWrite = true
        center.updateAttentionBadge(count: 6)
        await waitForBadge { self.badgeSink.pendingWrite != nil }
        center.updateAttentionBadge(count: 6)
        center.updateAttentionBadge(count: 7)
        center.updateAttentionBadge(count: 8)
        XCTAssertEqual(badgeSink.attempts, [6], "only one OS write may be in flight")
        badgeSink.resumeWrite()
        await waitForBadge { self.badgeSink.badge == 8 }
        center.updateAttentionBadge(count: 8)
        await center.refreshAuthorization()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(badgeSink.attempts, [6, 8])
    }

    func testAttentionBadgeOlderPositiveFollowedByZeroEndsAtZero() async {
        await assertOlderAttentionBadgeIsCleared(turnOff: false)
    }

    func testAttentionBadgeOlderPositiveFollowedByOffEndsAtZero() async {
        await assertOlderAttentionBadgeIsCleared(turnOff: true)
    }

    private func assertOlderAttentionBadgeIsCleared(turnOff: Bool) async {
        let center = makeCenter()
        await center.setEnabled(true)
        badgeSink.pauseNextWrite = true
        center.updateAttentionBadge(count: 11)
        await waitForBadge { self.badgeSink.pendingWrite != nil }
        if turnOff { await center.setEnabled(false) }
        else { center.updateAttentionBadge(count: 0) }
        XCTAssertEqual(badgeSink.attempts, [11], "clear must wait for the stale writer")
        badgeSink.resumeWrite()
        await waitForBadge { self.badgeSink.badge == 0 }
        XCTAssertEqual(badgeSink.attempts, [11, 0])
    }

    func testAttentionBadgeFailureRetriesSameCountAndForegroundRefresh() async {
        let center = makeCenter()
        await center.setEnabled(true)
        center.storageIssue = "existing storage issue"
        badgeSink.failNextWrite = true
        center.updateAttentionBadge(count: 5)
        await waitForBadge { center.badgeIssue != nil }
        XCTAssertEqual(badgeSink.attempts, [5])
        XCTAssertEqual(center.storageIssue, "existing storage issue")
        center.updateAttentionBadge(count: 5)
        await waitForBadge { self.badgeSink.badge == 5 && center.badgeIssue == nil }

        badgeSink.failNextWrite = true
        center.updateAttentionBadge(count: 0)
        await waitForBadge { center.badgeIssue != nil }
        await center.refreshAuthorization()
        await waitForBadge { self.badgeSink.badge == 0 && center.badgeIssue == nil }
        XCTAssertEqual(badgeSink.attempts, [5, 5, 0, 0])
        XCTAssertEqual(center.storageIssue, "existing storage issue")
    }

    private func waitForBadge(file: StaticString = #filePath, line: UInt = #line,
                              _ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "badge writer did not reach expected state", file: file, line: line)
    }

    func testPermissionFollowsAppSwitchIOSAndPerNodeOptOut() async {
        let center = makeCenter()
        XCTAssertEqual(center.permission(origin: origin, scope: "/node/a"), .default, "off until enabled")

        await center.setEnabled(true)
        XCTAssertEqual(authorizer.requests, 1, "turning on asks iOS once")
        XCTAssertEqual(center.permission(origin: origin, scope: "/node/a"), .granted)
        XCTAssertEqual(center.permission(origin: origin, scope: "/node/b"), .granted, "every node enrolls without another click")
        XCTAssertEqual(registrations, 1)

        center.disable(origin: origin, scope: "/node/a")
        XCTAssertEqual(center.permission(origin: origin, scope: "/node/a"), .default)
        XCTAssertEqual(center.permission(origin: origin, scope: "/node/b"), .granted, "opt-out is per node")
        let enabledAgain = await center.requestPermission(origin: origin, scope: "/node/a")
        XCTAssertEqual(enabledAgain, .granted, "the web UI's Enable clears the opt-out")
        XCTAssertEqual(authorizer.requests, 1)

        let before = center.changeCount
        await center.setEnabled(false)
        XCTAssertEqual(center.permission(origin: origin, scope: "/node/b"), .default)
        XCTAssertGreaterThan(center.changeCount, before, "pages reconcile and drop their server subscriptions")

        let restored = makeCenter()
        await restored.refreshAuthorization()
        XCTAssertFalse(restored.enabled, "persisted")
    }

    func testWebEnableTurnsOnAppAndDeniedIsReported() async {
        let center = makeCenter()
        let granted = await center.requestPermission(origin: origin, scope: "")
        XCTAssertEqual(granted, .granted)
        XCTAssertTrue(center.enabled, "one step: enabling from a site turns the app switch on")

        authorizer.current = .denied
        await center.refreshAuthorization()
        XCTAssertEqual(center.permission(origin: origin, scope: ""), .denied)

        let denying = makeCenter()
        authorizer.current = .notDetermined
        authorizer.grant = false
        let refused = await denying.requestPermission(origin: origin, scope: "")
        XCTAssertEqual(refused, .denied)
    }

    func testSubscribeRegistersWithRelayAndReusesRecord() async throws {
        let center = makeCenter()
        await center.setEnabled(true)
        let subscription = try await center.subscribe(origin: origin, scope: "/node/a", applicationServerKey: serverKey)
        XCTAssertEqual(subscription.endpoint, "https://relay.example/v1/push/TOKEN")
        XCTAssertEqual(subscription.applicationServerKey, serverKey)
        XCTAssertEqual(Data(base64URLEncoded: subscription.p256dh)?.count, 65)
        XCTAssertEqual(Data(base64URLEncoded: subscription.auth)?.count, 16)

        let request = try XCTUnwrap(relayRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://relay.example/v1/register")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String])
        XCTAssertEqual(body, ["device_token": "abcdef0123456789", "environment": "development", "application_server_key": serverKey])

        XCTAssertEqual(center.subscription(origin: origin, scope: "/node/a"), subscription)
        XCTAssertNil(center.subscription(origin: origin, scope: "/node/b"))
        XCTAssertNil(center.subscription(origin: "https://other.example", scope: "/node/a"))

        let identity = try XCTUnwrap(PushIdentityStore(storage: storage).load())
        let tag = WebPushCrypto.sourceTag(applicationServerKey: Data(base64URLEncoded: serverKey)!)
        XCTAssertEqual(identity.routes[tag], origin, "lets the extension attribute pushes to this server")

        center.unsubscribe(origin: origin, scope: "/node/a")
        XCTAssertNil(center.subscription(origin: origin, scope: "/node/a"))
        XCTAssertEqual(center.permission(origin: origin, scope: "/node/a"), .granted, "unsubscribe is not an opt-out")
    }

    func testDisableAndReenableRejectsStaleRelayRegistration() async throws {
        let center = makeCenter()
        await center.setEnabled(true)
        let started = expectation(description: "fake relay waiting")
        var release: CheckedContinuation<Void, Never>?
        relayBeforeReply = {
            await withCheckedContinuation { continuation in release = continuation; started.fulfill() }
        }
        let registration = Task { try await center.subscribe(origin: origin, scope: "/ui", applicationServerKey: serverKey) }
        await fulfillment(of: [started], timeout: 2)
        await center.setEnabled(false)
        await center.setEnabled(true)
        release?.resume()
        do { _ = try await registration.value; XCTFail("stale enrollment must not return an endpoint") }
        catch { XCTAssertEqual(error as? PushError, .notAllowed) }
        XCTAssertNil(center.subscription(origin: origin, scope: "/ui"))
        XCTAssertEqual(try deliveries.pending().count, 0, "stateless relay registration alone creates no server subscription")
    }

    func testOffRetainsEndpointAndLateServerIDUntilAuthenticatedCleanupACK() async throws {
        let center = makeCenter()
        await center.setEnabled(true)
        _ = try await center.subscribe(origin: origin, scope: "/ui", applicationServerKey: serverKey)
        await center.setEnabled(false)
        XCTAssertEqual(try deliveries.pending().count, 1)
        XCTAssertNil(try deliveries.pending().first?.subscriptionID, "pre-callback cleanup handle is not discarded")
        try center.recordEnrollment(origin: origin, scope: "/ui", subscriptionID: "server-sub")
        XCTAssertEqual(try deliveries.pending().first?.subscriptionID, "server-sub")
        let restored = makeCenter()
        XCTAssertFalse(restored.enabled)
        XCTAssertEqual(try deliveries.pending().first?.subscriptionID, "server-sub")
        try restored.acknowledgeCleanup(origin: origin, scope: "/ui", subscriptionID: "server-sub")
        _ = makeCenter()
        XCTAssertEqual(try deliveries.pending().count, 0, "restart cannot recreate acknowledged cleanup")
    }

    func testRelayedPushDecryptsWithTheSubscribedKeys() async throws {
        let center = makeCenter()
        await center.setEnabled(true)
        let subscription = try await center.subscribe(origin: origin, scope: "/ui", applicationServerKey: serverKey)
        let identity = try XCTUnwrap(PushIdentityStore(storage: storage).load())
        let tag = WebPushCrypto.sourceTag(applicationServerKey: Data(base64URLEncoded: serverKey)!)
        let payload = try relayedPayload(#"{"version":1,"event_id":"legacy-completion","outcome":"completed","title":"Response complete","body":"ready","url":"/ui/chat/s1","session_id":"s1"}"#,
                                         identity: identity, tag: tag, authSecret: Data(base64URLEncoded: subscription.auth))
        let message = try PushMessage.decode(userInfo: payload, identity: PushIdentityStore(storage: storage).load())
        XCTAssertEqual(message.url?.absoluteString, "https://hub.example/ui/chat/s1")
    }

    func testSharedVAPIDKeyDoesNotRouteDevNotificationsToLastVisitedHub() async throws {
        let center = makeCenter()
        await center.setEnabled(true)
        let dev = try await center.subscribe(origin: origin, scope: "/node/Dev", applicationServerKey: serverKey,
                                             label: "Dev", nodeBasePath: "/ui")
        let hub = try await center.subscribe(origin: origin, scope: "/", applicationServerKey: serverKey, label: "Hub")
        XCTAssertEqual(dev.p256dh, hub.p256dh)
        XCTAssertNotEqual(dev.auth, hub.auth, "VAPID keys identify servers, not individual node enrollments")
        let tag = WebPushCrypto.sourceTag(applicationServerKey: Data(base64URLEncoded: serverKey)!)
        for lastVisited in ["/node/Dev", "/"] {
            _ = center.subscription(origin: origin, scope: lastVisited)
            let identity = try XCTUnwrap(PushIdentityStore(storage: storage).load())
            for (subscription, title, path) in [(dev, "Dev", "/node/Dev/"), (hub, "Hub", "/")] {
                let auth = try XCTUnwrap(Data(base64URLEncoded: subscription.auth))
                let payload = try relayedPayload(#"{"title":"term-llm","body":"hello"}"#,
                                                 identity: identity, tag: tag, authSecret: auth)
                let message = try PushMessage.decode(userInfo: payload, identity: identity)
                XCTAssertEqual(message.title, title)
                XCTAssertEqual(message.url?.absoluteString, origin + path)
            }
            let payload = try relayedPayload(#"{"title":"Response complete","url":"/ui/chat/s1"}"#,
                                             identity: identity, tag: tag, authSecret: Data(base64URLEncoded: dev.auth))
            let completion = try PushMessage.decode(userInfo: payload, identity: identity)
            XCTAssertEqual(completion.url?.absoluteString, origin + "/node/Dev/chat/s1")
            XCTAssertEqual(completion.title, "Dev: Response complete")
            let legacy = try relayedPayload(#"{"title":"term-llm","body":"old"}"#, identity: identity, tag: tag)
            let ambiguous = try PushMessage.decode(userInfo: legacy, identity: identity)
            XCTAssertNil(ambiguous.url, "old shared-key pushes must not guess the last enrolled agent")
            XCTAssertEqual(ambiguous.title, "term-llm")
        }
        XCTAssertEqual(center.subscription(origin: origin, scope: "/node/Dev")?.auth, dev.auth)
        let restored = makeCenter()
        await restored.refreshAuthorization()
        XCTAssertEqual(restored.subscription(origin: origin, scope: "/node/Dev")?.auth, dev.auth,
                       "scoped authentication must survive an app restart")
    }

    func testScopedAuthenticationIsBoundToSourceTagAndOrigin() throws {
        let store = PushIdentityStore(storage: storage)
        _ = try store.loadOrCreate()
        try store.setRoute(tag: "key", origin: origin, scope: "/node/Dev", label: "Dev")
        try store.setRoute(tag: "key", origin: "https://other.example", scope: "/node/Dev", label: "Other")
        let identity = try XCTUnwrap(store.load())
        let auth = identity.authenticationSecret(tag: "key", origin: origin, scope: "/node/Dev")
        XCTAssertNotEqual(auth, identity.authenticationSecret(tag: "key", origin: "https://other.example", scope: "/node/Dev"))
        let payload = try relayedPayload(#"{"body":"hello"}"#, identity: identity, tag: "key", authSecret: auth)
        XCTAssertEqual(try PushMessage.decode(userInfo: payload, identity: identity).origin, origin)
        let wrongTag = try relayedPayload(#"{"body":"hello"}"#, identity: identity, tag: "other-key", authSecret: auth)
        XCTAssertThrowsError(try PushMessage.decode(userInfo: wrongTag, identity: identity))
    }

    func testTokenChangeInvalidatesRecordsAndNotifiesPages() async throws {
        let center = makeCenter()
        await center.setEnabled(true)
        _ = try await center.subscribe(origin: origin, scope: "", applicationServerKey: serverKey)
        XCTAssertNotNil(center.subscription(origin: origin, scope: ""))
        let before = center.changeCount
        center.didRegister(deviceToken: Data([1, 2, 3, 4, 5, 6, 7, 8]))
        XCTAssertGreaterThan(center.changeCount, before)
        XCTAssertNil(center.subscription(origin: origin, scope: ""), "endpoint embeds the old token; page re-enrolls")
    }

    func testSubscribeFailures() async {
        let center = makeCenter()
        await assertThrows(PushError.notAllowed) {
            _ = try await center.subscribe(origin: self.origin, scope: "", applicationServerKey: self.serverKey)
        }
        await center.setEnabled(true)
        await assertThrows(PushError.invalidServerKey) {
            _ = try await center.subscribe(origin: self.origin, scope: "", applicationServerKey: "AAAA")
        }
        relayResponse = (500, "{}")
        await assertThrows(PushError.relayRejected(500)) {
            _ = try await center.subscribe(origin: self.origin, scope: "", applicationServerKey: self.serverKey)
        }
        relayResponse = (200, #"{"endpoint":"https://evil.example/v1/push/x"}"#)
        await assertThrows(PushError.invalidRelayResponse) {
            _ = try await center.subscribe(origin: self.origin, scope: "", applicationServerKey: self.serverKey)
        }
        defaults.set("http://relay.example", forKey: PushCenter.relayOverrideKey)
        XCTAssertNil(center.relayURL.flatMap { $0.host == "relay.example" ? $0 : nil }, "plain HTTP only for loopback")
    }

    func testTokenTimeout() async {
        let center = makeCenter(deliverToken: false, timeout: .milliseconds(50))
        await center.setEnabled(true)
        await assertThrows(PushError.registrationTimedOut) {
            _ = try await center.subscribe(origin: self.origin, scope: "", applicationServerKey: self.serverKey)
        }
    }

    func testRelayUnsupportedEnvironmentIsActionable() async {
        let relay = PushRelayClient(baseURL: URL(string: "https://push.example")!) { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"code":"unsupported_environment","error":"environment is not enabled"}"#.utf8), response)
        }
        await assertThrows(PushError.relayEnvironmentUnsupported(.development)) {
            _ = try await relay.register(deviceToken: "aabb", environment: .development, applicationServerKey: self.serverKey)
        }
        XCTAssertTrue(PushError.relayEnvironmentUnsupported(.development).localizedDescription.contains("development"))
        XCTAssertTrue(PushError.relayEnvironmentUnsupported(.development).localizedDescription.contains("APNs key"))
    }

    func testOtherRelay422RemainsGeneric() async {
        let relay = PushRelayClient(baseURL: URL(string: "https://push.example")!) { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"error":"some other validation error"}"#.utf8), response)
        }
        await assertThrows(PushError.relayRejected(422)) {
            _ = try await relay.register(deviceToken: "aabb", environment: .production, applicationServerKey: self.serverKey)
        }
    }

    func testRelayURLValidation() {
        XCTAssertEqual(PushRelayClient.validatedBaseURL("https://push.term-llm.com/")?.absoluteString, "https://push.term-llm.com")
        XCTAssertEqual(PushRelayClient.validatedBaseURL("http://localhost:8080")?.absoluteString, "http://localhost:8080")
        for bad in [nil, "", "$(TERMLLM_PUSH_RELAY_URL)", "http://push.term-llm.com", "https://push.term-llm.com/x",
                    "https://u:p@push.term-llm.com", "ftp://push.term-llm.com"] {
            XCTAssertNil(PushRelayClient.validatedBaseURL(bad), bad ?? "nil")
        }
    }

    func testCachedSubscriptionRefreshesAgentMetadataWithoutRelayRegistration() async throws {
        let center = makeCenter()
        await center.setEnabled(true)
        let scope = "/hub/nodes/Dev"
        _ = try await center.subscribe(origin: origin, scope: scope, applicationServerKey: serverKey)
        let tag = WebPushCrypto.sourceTag(applicationServerKey: Data(base64URLEncoded: serverKey)!)
        // Simulate an existing installation whose identity only stored origins.
        var identity = try XCTUnwrap(PushIdentityStore(storage: storage).load())
        identity.routeDetails = nil
        identity.scopedRoutes = nil
        try storage.write(JSONEncoder().encode(identity))
        let requestCount = relayRequests.count
        let result = await NativePushBridge.handle(body: ["method": "getSubscription", "scope": scope, "label": "Dev"],
                                                  frameOrigin: origin, isMainFrame: true, expectedOrigin: origin, center: center)
        let value = try XCTUnwrap(try result.get() as? [String: Any])
        let keys = try XCTUnwrap(value["keys"] as? [String: String])
        let auth = try XCTUnwrap(keys["auth"].flatMap { Data(base64URLEncoded: $0) })
        XCTAssertNotEqual(auth, identity.authSecret, "cached enrollment migrates to a scope-bound secret")
        XCTAssertEqual(relayRequests.count, requestCount)
        identity = try XCTUnwrap(PushIdentityStore(storage: storage).load())
        XCTAssertEqual(identity.routeDetails?[tag]?.scope, scope)
        XCTAssertEqual(identity.routeDetails?[tag]?.label, "Dev")
        let payload = try relayedPayload(#"{"title":"term-llm","body":"hello"}"#, identity: identity, tag: tag, authSecret: auth)
        let message = try PushMessage.decode(userInfo: payload, identity: identity)
        defaults.set("https://hub.example/hub/", forKey: "serverURL")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            center.handleNotificationTap(urlString: message.userInfo[PushMessage.urlKey]) { continuation.resume() }
        }
        XCTAssertEqual(center.pendingNavigation?.url.absoluteString, "https://hub.example/hub/nodes/Dev/")
    }

    func testForegroundAlertsAndTapRouting() async {
        let center = makeCenter()
        await center.setEnabled(true)
        let message = PushMessage.message(from: ["title": "hello"], origin: origin, scope: "/ui")
        center.visibleURL = URL(string: "https://hub.example/ui/chat/s1/")
        XCTAssertEqual(center.presentationOptions(userInfo: message.userInfo), [.banner, .list, .sound], "same URL is not attendance")
        XCTAssertEqual(center.presentationOptions(userInfo: message.userInfo), [.banner, .list, .sound])
        XCTAssertEqual(center.presentationOptions(userInfo: [:]), [])
        center.isActive = { false }
        XCTAssertEqual(center.presentationOptions(userInfo: message.userInfo), [.banner, .list, .sound])

        let server = URL(string: "https://hub.example/ui/")
        center.open(urlString: "https://other.example/ui/chat/1", configuredServer: server)
        XCTAssertNil(center.pendingNavigation, "pushes from another server only open the app")
        center.open(urlString: "https://hub.example/node/a/chat/1", configuredServer: server)
        let navigation = try? XCTUnwrap(center.pendingNavigation)
        XCTAssertEqual(navigation?.url.absoluteString, "https://hub.example/node/a/chat/1")
        center.navigationHandled(navigation!.id)
        XCTAssertNil(center.pendingNavigation)
    }

    func testTapRoutesToOwningSavedConnectionNotJustTheSelectedOne() throws {
        let center = makeCenter()
        let hub = HubConnection(id: UUID(), name: "Hub", kind: .hub, url: URL(string: "https://hub.example/ui/")!)
        let node = HubConnection(id: UUID(), name: "Dev", kind: .directNode, url: URL(string: "https://hub.example/ui/node/dev/")!)
        let other = HubConnection(id: UUID(), name: "Other", kind: .directNode, url: URL(string: "https://other.example/")!)
        var review = HubConnection(id: UUID(), name: "Review", kind: .hub, url: URL(string: "https://review.example/")!)
        review.needsKindReview = true
        let saved = [hub, node, other, review]

        // A different origin from the selected connection still finds its owner.
        center.open(urlString: "https://other.example/chat/1", configuredServer: hub.url,
                    connections: saved, selectedConnectionID: hub.id)
        XCTAssertEqual(center.pendingNavigation?.connectionID, other.id)
        XCTAssertEqual(center.pendingNavigation?.url.absoluteString, "https://other.example/chat/1")

        // The most specific mount wins over a containing hub mount.
        center.open(urlString: "https://hub.example/ui/node/dev/chat/2", configuredServer: hub.url,
                    connections: saved, selectedConnectionID: hub.id)
        XCTAssertEqual(center.pendingNavigation?.connectionID, node.id)
        center.open(urlString: "https://hub.example/ui/chat/3", configuredServer: hub.url,
                    connections: saved, selectedConnectionID: node.id)
        XCTAssertEqual(center.pendingNavigation?.connectionID, hub.id)
        let previous = try XCTUnwrap(center.pendingNavigation)

        // Unowned taps (unknown server, connection awaiting review, outside every
        // mount) only open the app and never replace a pending destination.
        for url in ["https://unknown.example/chat/1", "https://review.example/chat/1", "https://hub.example/elsewhere/"] {
            center.open(urlString: url, configuredServer: hub.url, connections: saved, selectedConnectionID: hub.id)
            XCTAssertEqual(center.pendingNavigation, previous, url)
        }
    }

    func testOwningConnectionPrefersSelectedOnEqualMounts() {
        let a = HubConnection(id: UUID(), name: "A", kind: .hub, url: URL(string: "https://hub.example/ui/")!)
        let b = HubConnection(id: UUID(), name: "B", kind: .hub, url: URL(string: "https://hub.example/ui/")!)
        let url = URL(string: "https://hub.example/ui/chat/1")!
        XCTAssertEqual(PushCenter.owningConnection(for: url, in: [a, b], selectedID: b.id)?.id, b.id)
        XCTAssertEqual(PushCenter.owningConnection(for: url, in: [a, b], selectedID: a.id)?.id, a.id)
    }

    func testNotificationTapCompletesOnMainThreadAfterRouting() async {
        defaults.set("https://hub.example/ui/", forKey: "serverURL")
        let center = makeCenter()
        let target = "https://hub.example/ui/chat/s1"
        await Task.detached {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                center.handleNotificationTap(urlString: target) {
                    XCTAssertTrue(Thread.isMainThread, "UIKit's notification completion must run on the main thread")
                    MainActor.assumeIsolated {
                        XCTAssertEqual(center.pendingNavigation?.url.absoluteString, target,
                                       "route the tap before completing the system callback")
                    }
                    continuation.resume()
                }
            }
        }.value
    }

    func testNotificationTapWithoutTrustedURLStillCompletesOnMainThread() async {
        defaults.set("https://hub.example/ui/", forKey: "serverURL")
        let center = makeCenter()
        // `term-llm notify app hello` need not contain a chat URL. Both that
        // case and an unrelated server must complete, without navigating.
        for url in [nil, "https://other.example/ui/chat/s1"] as [String?] {
            await Task.detached {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    center.handleNotificationTap(urlString: url) {
                        XCTAssertTrue(Thread.isMainThread)
                        MainActor.assumeIsolated { XCTAssertNil(center.pendingNavigation) }
                        continuation.resume()
                    }
                }
            }.value
        }
    }

    func testProvisioningProfileEnvironment() {
        func profile(_ entitlements: String) -> Data {
            Data("garbage\u{0}<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Entitlements</key><dict>\(entitlements)</dict></dict></plist>\u{0}sig".utf8)
        }
        XCTAssertEqual(PushEnvironment.parse(provisioningProfile: profile("<key>aps-environment</key><string>development</string>")), .development)
        XCTAssertEqual(PushEnvironment.parse(provisioningProfile: profile("<key>aps-environment</key><string>production</string>")), .production)
        XCTAssertNil(PushEnvironment.parse(provisioningProfile: profile("")))
        XCTAssertNil(PushEnvironment.parse(provisioningProfile: Data("nope".utf8)))
    }

    // MARK: Bridge

    func testBridgeValidatesCallerAndDispatches() async throws {
        let center = makeCenter()
        func call(_ body: Any, origin: String? = nil, mainFrame: Bool = true) async -> Result<Any, NativePushBridge.BridgeError> {
            await NativePushBridge.handle(body: body, frameOrigin: origin ?? self.origin, isMainFrame: mainFrame,
                                          expectedOrigin: self.origin, center: center)
        }
        func value(_ result: Result<Any, NativePushBridge.BridgeError>) -> Any? { try? result.get() }

        let rejected = await call(["method": "permission", "scope": ""], origin: "https://evil.example")
        XCTAssertThrowsError(try rejected.get())
        let subframe = await call(["method": "permission", "scope": ""], mainFrame: false)
        XCTAssertThrowsError(try subframe.get())
        for scope in ["no-slash", "/a?b", "/a#b", String(repeating: "/a", count: 300)] {
            let bad = await call(["method": "permission", "scope": scope])
            XCTAssertThrowsError(try bad.get(), scope)
        }
        let unknown = await call(["method": "explode", "scope": ""])
        XCTAssertThrowsError(try unknown.get())

        let initial = await call(["method": "permission", "scope": "/ui"])
        XCTAssertEqual(value(initial) as? String, "default")
        let requested = await call(["method": "requestPermission", "scope": "/ui"])
        XCTAssertEqual(value(requested) as? String, "granted")
        let none = await call(["method": "getSubscription", "scope": "/ui"])
        XCTAssertTrue(value(none) is NSNull)

        let subscribeResult = await call(["method": "subscribe", "scope": "/ui", "applicationServerKey": serverKey])
        let subscribed = value(subscribeResult) as? [String: Any]
        XCTAssertEqual(subscribed?["endpoint"] as? String, "https://relay.example/v1/push/TOKEN")
        XCTAssertEqual(subscribed?["applicationServerKey"] as? String, serverKey)
        XCTAssertNotNil((subscribed?["keys"] as? [String: String])?["p256dh"])
        let existingResult = await call(["method": "getSubscription", "scope": "/ui"])
        let existing = value(existingResult) as? [String: Any]
        XCTAssertEqual(existing?["endpoint"] as? String, "https://relay.example/v1/push/TOKEN")

        let failed = await call(["method": "subscribe", "scope": "/ui", "applicationServerKey": "AAAA"])
        if case .failure(let error) = failed {
            XCTAssertEqual(error.message, PushError.invalidServerKey.localizedDescription)
        } else { XCTFail("expected failure") }

        let disabled = await call(["method": "disable", "scope": "/ui"])
        XCTAssertEqual(value(disabled) as? Bool, true)
        let after = await call(["method": "permission", "scope": "/ui"])
        XCTAssertEqual(value(after) as? String, "default")
    }

    func testInjectedScriptOnlyOnConfiguredOriginAndCoexistsWithWebMCP() async throws {
        let center = makeCenter()
        await center.setEnabled(true)
        let server = URL(string: "https://hub.example/ui/")!
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let push = NativePushBridge(serverURL: server, center: center)
        push.install(into: configuration.userContentController)
        let tools = WebMCPBridge(serverURL: server, registry: DeviceToolRegistry(tools: []), device: "iPhone")
        tools.install(into: configuration.userContentController)
        tools.uninstall()
        XCTAssertEqual(configuration.userContentController.userScripts.count, 1, "removing device tools keeps the push bridge")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)

        try await load(webView, baseURL: server)
        let permission = try await webView.callAsyncJavaScript(
            "return await window.__termLLMNativePush.permission('/ui')", contentWorld: .page) as? String
        XCTAssertEqual(permission, "granted")
        let version = try await webView.callAsyncJavaScript("return window.__termLLMNativePush.version", contentWorld: .page) as? Int
        XCTAssertEqual(version, 1)
        let missing = try await webView.callAsyncJavaScript(
            "return await window.__termLLMNativePush.getSubscription('/ui')", contentWorld: .page)
        XCTAssertTrue(missing == nil || missing is NSNull)

        try await load(webView, baseURL: URL(string: "https://hub.example/node/Dev/")!)
        _ = try await webView.callAsyncJavaScript("""
            window.TERM_LLM_HUB = { nodeName: 'Dev', nodeBasePath: '/ui' };
            return await window.__termLLMNativePush.subscribe('/node/Dev', key);
            """, arguments: ["key": serverKey], contentWorld: .page)
        let tag = WebPushCrypto.sourceTag(applicationServerKey: Data(base64URLEncoded: serverKey)!)
        let route = try XCTUnwrap(PushIdentityStore(storage: storage).load()?.routeDetails?[tag])
        XCTAssertEqual(route.scope, "/node/Dev")
        XCTAssertEqual(route.label, "Dev")
        XCTAssertEqual(route.nodeBasePath, "/ui")

        try await load(webView, baseURL: URL(string: "https://evil.example/")!)
        let other = try await webView.callAsyncJavaScript("return typeof window.__termLLMNativePush", contentWorld: .page) as? String
        XCTAssertEqual(other, "undefined")
    }

    // MARK: Helpers

    private func load(_ webView: WKWebView, baseURL: URL) async throws {
        let waiter = PushNavigationWaiter()
        webView.navigationDelegate = waiter
        webView.loadHTMLString("<!doctype html><html><body>term-llm</body></html>", baseURL: baseURL)
        try await waiter.wait()
    }

    private func assertThrows(_ expected: PushError, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? PushError, expected, file: file, line: line)
        }
    }
}

// MARK: - Test support

@MainActor
private final class FakeBadgeSink {
    var badge = 99 // Model an existing OS badge from before this app launch.
    var attempts: [Int] = []
    var pauseNextWrite = false
    var failNextWrite = false
    var pendingWrite: CheckedContinuation<Void, Never>?

    func set(_ count: Int) async throws {
        attempts.append(count)
        if pauseNextWrite {
            pauseNextWrite = false
            await withCheckedContinuation { pendingWrite = $0 }
        }
        if failNextWrite {
            failNextWrite = false
            throw NSError(domain: "FakeBadgeSink", code: 1)
        }
        badge = count
    }

    func resumeWrite() {
        let pending = pendingWrite
        pendingWrite = nil
        pending?.resume()
    }
}

private final class FakeAuthorizer: PushAuthorizer, @unchecked Sendable { // driven serially by tests
    var current: UNAuthorizationStatus = .notDetermined
    var grant = true
    var requests = 0

    func status() async -> UNAuthorizationStatus { current }

    func request() async throws -> Bool {
        requests += 1
        current = grant ? .authorized : .denied
        return grant
    }
}

private final class PushNavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func wait() async throws {
        if let result { return try result.get() }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    private func finish(_ result: Result<Void, Error>) {
        if let continuation {
            continuation.resume(with: result)
            self.continuation = nil
        } else {
            self.result = result
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
}

/// The sending side of RFC 8291, as term-llm (webpush-go) does it.
func encryptWebPush(_ plaintext: Data, identity: PushIdentity, recordSize: Int = 2048, authSecret: Data? = nil) throws -> Data {
    let receiver = try identity.agreementKey().publicKey
    let sender = P256.KeyAgreement.PrivateKey()
    let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    let ecdh = try sender.sharedSecretFromKeyAgreement(with: receiver).withUnsafeBytes { Data($0) }
    let keyInfo = Data("WebPush: info".utf8) + Data([0]) + receiver.x963Representation + sender.publicKey.x963Representation
    let ikm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ecdh), salt: authSecret ?? identity.authSecret, info: keyInfo, outputByteCount: 32)
    let cek = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: aes128gcm".utf8) + Data([0]), outputByteCount: 16)
    let nonce = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: nonce".utf8) + Data([0]), outputByteCount: 12)
    var header = salt
    header += withUnsafeBytes(of: UInt32(recordSize).bigEndian) { Data($0) }
    header += Data([65]) + sender.publicKey.x963Representation
    var padded = plaintext + Data([0x02])
    padded += Data(count: recordSize - header.count - 16 - padded.count)
    let sealed = try AES.GCM.seal(padded, using: cek, nonce: AES.GCM.Nonce(data: nonce.withUnsafeBytes { Data($0) }))
    return header + sealed.ciphertext + sealed.tag
}

/// The APNs userInfo the relay produces for a Web Push message.
func relayedPayload(_ json: String, identity: PushIdentity, tag: String, authSecret: Data? = nil) throws -> [AnyHashable: Any] {
    let body = try encryptWebPush(Data(json.utf8), identity: identity, authSecret: authSecret)
    return [
        "aps": ["alert": ["title": "term-llm", "body": "New notification"], "mutable-content": 1],
        "webpush": ["v": 1, "ce": "aes128gcm", "k": tag, "body": body.base64EncodedString()],
    ]
}
