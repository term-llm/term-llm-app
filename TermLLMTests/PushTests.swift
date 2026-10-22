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
    private var authorizer: FakeAuthorizer!
    private var storage: InMemoryPushStorage!
    private var relayRequests: [URLRequest] = []
    private var relayResponse: (Int, String) = (200, #"{"endpoint":"https://relay.example/v1/push/TOKEN"}"#)
    private var registrations = 0
    private var token = Data([0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89])

    override func setUp() async throws {
        suite = "push-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.set("https://relay.example", forKey: PushCenter.relayOverrideKey)
        authorizer = FakeAuthorizer()
        storage = InMemoryPushStorage()
        relayRequests = []
        registrations = 0
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeCenter(deliverToken: Bool = true, timeout: Duration = .seconds(5)) -> PushCenter {
        var centerRef: PushCenter?
        let center = PushCenter(
            defaults: defaults, identities: PushIdentityStore(storage: storage), authorizer: authorizer,
            relayTransport: { [unowned self] request in
                relayRequests.append(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: relayResponse.0, httpVersion: nil, headerFields: nil)!
                return (Data(relayResponse.1.utf8), response)
            },
            registerForRemote: { [unowned self] in
                registrations += 1
                guard deliverToken else { return }
                let token = token
                Task { @MainActor in centerRef?.didRegister(deviceToken: token) }
            },
            environment: .development, tokenTimeout: timeout)
        centerRef = center
        center.isActive = { true }
        return center
    }

    private let serverKey = P256.Signing.PrivateKey().publicKey.x963Representation.base64URLEncodedString()

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

    func testRelayedPushDecryptsWithTheSubscribedKeys() async throws {
        let center = makeCenter()
        await center.setEnabled(true)
        _ = try await center.subscribe(origin: origin, scope: "/ui", applicationServerKey: serverKey)
        let identity = try XCTUnwrap(PushIdentityStore(storage: storage).load())
        let tag = WebPushCrypto.sourceTag(applicationServerKey: Data(base64URLEncoded: serverKey)!)
        let payload = try relayedPayload(#"{"title":"Response complete","body":"ready","url":"/ui/chat/s1","session_id":"s1"}"#,
                                         identity: identity, tag: tag)
        let message = try PushMessage.decode(userInfo: payload, identity: PushIdentityStore(storage: storage).load())
        XCTAssertEqual(message.url?.absoluteString, "https://hub.example/ui/chat/s1")
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

    func testForegroundAlertsAndTapRouting() {
        let center = makeCenter()
        center.visibleURL = URL(string: "https://hub.example/ui/chat/s1/")
        XCTAssertEqual(center.presentationOptions(forURL: "https://hub.example/ui/chat/s1"), [], "already looking at it")
        XCTAssertEqual(center.presentationOptions(forURL: "https://hub.example/ui/chat/s2"), [.banner, .list, .sound])
        XCTAssertEqual(center.presentationOptions(forURL: nil), [.banner, .list, .sound])
        center.isActive = { false }
        XCTAssertEqual(center.presentationOptions(forURL: "https://hub.example/ui/chat/s1"), [.banner, .list, .sound])

        let server = URL(string: "https://hub.example/ui/")
        center.open(urlString: "https://other.example/ui/chat/1", configuredServer: server)
        XCTAssertNil(center.pendingNavigation, "pushes from another server only open the app")
        center.open(urlString: "https://hub.example/node/a/chat/1", configuredServer: server)
        let navigation = try? XCTUnwrap(center.pendingNavigation)
        XCTAssertEqual(navigation?.url.absoluteString, "https://hub.example/node/a/chat/1")
        center.navigationHandled(navigation!.id)
        XCTAssertNil(center.pendingNavigation)
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

private final class FakeAuthorizer: PushAuthorizer {
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
func encryptWebPush(_ plaintext: Data, identity: PushIdentity, recordSize: Int = 2048) throws -> Data {
    let receiver = try identity.agreementKey().publicKey
    let sender = P256.KeyAgreement.PrivateKey()
    let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    let ecdh = try sender.sharedSecretFromKeyAgreement(with: receiver).withUnsafeBytes { Data($0) }
    let keyInfo = Data("WebPush: info".utf8) + Data([0]) + receiver.x963Representation + sender.publicKey.x963Representation
    let ikm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ecdh), salt: identity.authSecret, info: keyInfo, outputByteCount: 32)
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
func relayedPayload(_ json: String, identity: PushIdentity, tag: String) throws -> [AnyHashable: Any] {
    let body = try encryptWebPush(Data(json.utf8), identity: identity)
    return [
        "aps": ["alert": ["title": "term-llm", "body": "New notification"], "mutable-content": 1],
        "webpush": ["v": 1, "ce": "aes128gcm", "k": tag, "body": body.base64EncodedString()],
    ]
}
