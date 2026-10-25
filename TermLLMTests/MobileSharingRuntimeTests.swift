import XCTest
@testable import TermLLM

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

private final class MobileSharingForwarder: PeerHTTPForwarding, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var paths: [String] = []
    let status: Int
    init(status: Int = 200) { self.status = status }
    func forward(_ request: PeerHTTPRequest, headTimeout: TimeInterval?) async throws -> PeerHTTPResponse {
        lock.withLock { paths.append(request.path) }
        var header = PeerHeader()
        header.set("Content-Type", "application/json")
        return PeerHTTPResponse(status: status, header: header,
                                body: .fixed([Data("{\"ok\":true}".utf8)]), cancel: {})
    }
}

final class MobileSharingRuntimeTests: XCTestCase {
    @MainActor
    func testCatalogKeysPeerByHostIdentityAndKeepsStableOrigin() throws {
        let suite = "MobileSharingRuntimeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HubConnectionStore(defaults: defaults)
        let host = Data(repeating: 7, count: 32)
        let first = try store.saveMobileSharing(name: "Desk", hostKey: host, bridgePort: 43210, basePath: "/agent")
        XCTAssertTrue(first.isMobileSharing)
        XCTAssertEqual(first.url.absoluteString, "http://localhost:43210/agent/")

        let renamed = try store.saveMobileSharing(name: "Renamed", hostKey: host, bridgePort: 54321, basePath: "/other")
        XCTAssertEqual(renamed.id, first.id)
        XCTAssertEqual(renamed.url, first.url, "re-pairing cannot silently change the stable WebKit origin")
        XCTAssertEqual(store.connections.count, 1)

        let document = try HubConnectionStore.validatedDocument(defaults.object(forKey: HubConnectionStore.storageKey))
        XCTAssertEqual(document.connections.first?.mobileSharingHostKey, MobileSharingBase64URL.encode(host))
    }

    @MainActor
    func testCatalogRejectsDuplicateLoopbackOriginAndCorruptHostKey() throws {
        let suite = "MobileSharingRuntimeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HubConnectionStore(defaults: defaults)
        _ = try store.saveMobileSharing(name: "One", hostKey: Data(repeating: 1, count: 32), bridgePort: 43211)
        XCTAssertThrowsError(try store.saveMobileSharing(name: "Two", hostKey: Data(repeating: 2, count: 32), bridgePort: 43211))
    }

    func testPeerSourceCannotOwnNativePushRoute() throws {
        let peer = HubConnection(id: UUID(), name: "Peer", kind: .directNode,
                                 url: try XCTUnwrap(URL(string: "http://localhost:43214/")),
                                 mobileSharingHostKey: MobileSharingBase64URL.encode(Data(repeating: 8, count: 32)))
        XCTAssertNil(PushCenter.owningConnection(for: peer.url.appendingPathComponent("chat/1"),
                                                  in: [peer], selectedID: peer.id))
        XCTAssertNil(PushCenter.resolveDestination(peer.url.appendingPathComponent("chat/1"), scope: "/",
                                                    in: [peer], selectedID: peer.id))
    }

    func testReconnectBackoffIsBounded() {
        XCTAssertEqual(MobileSharingRuntime.backoffNanoseconds(attempt: 0), 1_000_000_000)
        XCTAssertEqual(MobileSharingRuntime.backoffNanoseconds(attempt: 5), 30_000_000_000)
        XCTAssertEqual(MobileSharingRuntime.backoffNanoseconds(attempt: 100), 30_000_000_000)
        XCTAssertTrue(MobileSharingRuntime.shouldStopAutomatically(MobileSharingBrokerError.superseded))
        XCTAssertTrue(MobileSharingRuntime.shouldStopAutomatically(MobileSharingBrokerError.quotaExceeded))
        XCTAssertFalse(MobileSharingRuntime.shouldStopAutomatically(MobileSharingBrokerError.notFound))
        XCTAssertFalse(MobileSharingRuntime.shouldStopAutomatically(MobileSharingBrokerError.peerOffline))
    }
}

final class PeerTransportTests: XCTestCase {
    func testFrameCodecIsStrictAndBounded() throws {
        var header = PeerHeader()
        header.set("accept", "application/json")
        let frame = PeerFrame(type: .request, id: "1", method: "GET", path: "/v1/sessions", header: header)
        XCTAssertEqual(try PeerFrameCodec.decode(PeerFrameCodec.encode(frame)), frame)
        XCTAssertThrowsError(try PeerFrameCodec.decode(Data(repeating: 0x20, count: PeerWireLimits.default.maxFrameBytes + 1)))
        XCTAssertThrowsError(try PeerFrameCodec.decode(Data("{\"version\":2,\"type\":\"request\",\"id\":\"1\",\"method\":\"GET\",\"path\":\"/\"}".utf8)))
    }

    func testLoopbackGateRequiresExactHostCapabilityAndScope() {
        let gate = PeerLoopbackGate(port: 43212, capability: "secret", scopePrefix: "/")
        func request(host: String, cookie: String?) -> PeerLoopbackRequest {
            var header = PeerHeader(); header.set("Host", host)
            if let cookie { header.set("Cookie", cookie) }
            return PeerLoopbackRequest(method: "GET", target: "/chat/1", version: "HTTP/1.1", header: header, body: Data())
        }
        XCTAssertEqual(gate.evaluate(request(host: "localhost:43212", cookie: "termllm_peer_43212=secret")), .allow)
        if case .allow = gate.evaluate(request(host: "127.0.0.1:43212", cookie: "termllm_peer_43212=secret")) {
            XCTFail("numeric-host rebinding bypassed exact localhost gate")
        }
        if case .allow = gate.evaluate(request(host: "localhost:43212", cookie: "termllm_peer_43212=wrong")) {
            XCTFail("wrong capability was accepted")
        }
    }

    func testNativePeerRequestStripsCredentialsAndProxyMetadata() throws {
        var request = URLRequest(url: URL(string: "http://localhost:43215/v1/sessions")!)
        request.setValue("Bearer owner", forHTTPHeaderField: "Authorization")
        request.setValue("session=owner", forHTTPHeaderField: "Cookie")
        request.setValue("https://owner.example", forHTTPHeaderField: "Origin")
        request.setValue("10.0.0.1", forHTTPHeaderField: "X-Forwarded-For")
        request.setValue("kept", forHTTPHeaderField: "X-Custom")
        let peer = try WebRTCHubTransport.peerRequest(from: request, url: request.url!)
        XCTAssertNil(peer.header.first("Authorization"))
        XCTAssertNil(peer.header.first("Cookie"))
        XCTAssertNil(peer.header.first("Origin"))
        XCTAssertNil(peer.header.first("X-Forwarded-For"))
        XCTAssertEqual(peer.header.first("X-Custom"), "kept")
    }

    func testRouteForbiddenDoesNotRevokePeerIdentity() async throws {
        let forwarder = MobileSharingForwarder(status: 403)
        let authorization = PeerAuthorizationState(PeerAuthorization(peerID: "host", sessionID: "session", expiresAt: .distantFuture))
        let transport = WebRTCHubTransport(forwarder: forwarder, authorization: authorization,
                                            hubBaseURL: URL(string: "http://localhost:43215/")!)
        let request = URLRequest(url: URL(string: "http://localhost:43215/v1/mobile-sharing")!)
        let callback = LockedFlag()
        await XCTAssertThrowsErrorAsync(try await transport.execute(request, onUnauthorized: { callback.set() }))
        XCTAssertFalse(callback.value)
        XCTAssertTrue(authorization.check())
    }

    func testSourceTransportNeverRetriesAcrossConnections() async throws {
        let source = MobileSharingSourceTransport()
        let url = try XCTUnwrap(URL(string: "http://localhost:43213/v1/sessions"))
        let request = URLRequest(url: url)
        await XCTAssertThrowsErrorAsync(try await source.execute(request, onUnauthorized: nil))

        let forwarder = MobileSharingForwarder()
        let authorization = PeerAuthorizationState(PeerAuthorization(peerID: "host", sessionID: "session", expiresAt: .distantFuture))
        source.install(WebRTCHubTransport(forwarder: forwarder, authorization: authorization,
                                          hubBaseURL: URL(string: "http://localhost:43213/")!))
        let (data, response) = try await source.execute(request, onUnauthorized: nil)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(data, Data("{\"ok\":true}".utf8))
        XCTAssertEqual(forwarder.paths, ["/v1/sessions"])
        source.disconnect()
        await XCTAssertThrowsErrorAsync(try await source.execute(request, onUnauthorized: nil))
        XCTAssertEqual(forwarder.paths, ["/v1/sessions"], "offline execution must not replay on an old transport")
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                          file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
