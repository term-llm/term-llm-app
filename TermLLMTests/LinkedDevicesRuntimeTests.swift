import Foundation
import Network
import WebKit
import XCTest
@testable import TermLLM

@MainActor
final class LinkedDevicesRuntimeTests: XCTestCase {
    @MainActor
    func testCatalogKeysPeerByHostIdentityAndKeepsStableOrigin() throws {
        let suite = "LinkedDevicesRuntimeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HubConnectionStore(defaults: defaults)
        let host = Data(repeating: 7, count: 32)
        let first = try store.saveLinkedDevices(name: "Desk", hostKey: host, bridgePort: 43210, basePath: "/agent")
        XCTAssertTrue(first.isLinkedDevices)
        XCTAssertEqual(first.url.absoluteString, "http://localhost:43210/agent/")

        let renamed = try store.saveLinkedDevices(name: "Renamed", hostKey: host, bridgePort: 54321, basePath: "/other")
        XCTAssertEqual(renamed.id, first.id)
        XCTAssertEqual(renamed.url.absoluteString, "http://localhost:43210/other/",
                       "re-pairing keeps the stable port but adopts the newly signed mount")
        XCTAssertEqual(store.connections.count, 1)

        let document = try HubConnectionStore.validatedDocument(defaults.object(forKey: HubConnectionStore.storageKey))
        XCTAssertEqual(document.connections.first?.linkedDevicesHostKey, LinkedDevicesBase64URL.encode(host))
    }

    @MainActor
    func testCatalogRoundTripsPeerUnderForcedPhysicalHTTPPolicyWithoutDroppingHTTPSSources() throws {
        let https = HubConnection(id: UUID(), name: "Existing", kind: .hub,
                                  url: try XCTUnwrap(URL(string: "https://hub.example/")))
        let peer = HubConnection(id: UUID(), name: "Phone peer", kind: .directNode,
                                 url: try XCTUnwrap(URL(string: "http://localhost:43216/chat/")),
                                 needsKindReview: nil,
                                 linkedDevicesHostKey: LinkedDevicesBase64URL.encode(Data(repeating: 9, count: 32)))
        let raw = try JSONEncoder().encode(HubConnectionStore.Document(connections: [https, peer], selectedID: https.id))
        let decoded = try HubConnectionStore.validatedDocument(raw) { input in
            // Force physical-device semantics: no ordinary HTTP URL is valid.
            guard !input.lowercased().hasPrefix("http:") else { return nil }
            return HubConnectionStore.canonicalURL(input)
        }
        XCTAssertEqual(decoded.connections, [https, peer])
        XCTAssertEqual(decoded.selectedID, https.id)

        var malicious = peer
        malicious.url = try XCTUnwrap(URL(string: "http://127.0.0.1:43216/chat/"))
        let bad = try JSONEncoder().encode(HubConnectionStore.Document(connections: [https, malicious], selectedID: https.id))
        XCTAssertThrowsError(try HubConnectionStore.validatedDocument(bad) { _ in nil })
    }

    func testPeerMountReplacementKeepsUUIDOwnedCapabilityStore() throws {
        let id = UUID()
        let hostKey = LinkedDevicesBase64URL.encode(Data(repeating: 0x19, count: 32))
        let old = HubConnection(id: id, name: "Desk", kind: .directNode,
                                url: try XCTUnwrap(URL(string: "http://localhost:43210/chat/")),
                                needsKindReview: nil, linkedDevicesHostKey: hostKey)
        var movedMount = old
        movedMount.url = try XCTUnwrap(URL(string: "http://localhost:43210/deep/mount/"))
        XCTAssertFalse(HubAggregateStore.shouldRemoveCredentialsWhenReplacing(old, with: movedMount))

        var changedOrigin = movedMount
        changedOrigin.url = try XCTUnwrap(URL(string: "http://localhost:43211/deep/mount/"))
        XCTAssertTrue(HubAggregateStore.shouldRemoveCredentialsWhenReplacing(old, with: changedOrigin))
        XCTAssertTrue(HubAggregateStore.shouldRemoveCredentialsWhenReplacing(old, with: nil))
    }

    func testUUIDBarrierWaitsForOldPurgeBeforeReplacementCookieWrite() async throws {
        let id = UUID()
        let oldConnection = HubConnection(id: id, name: "Desk", kind: .directNode,
                                          url: try XCTUnwrap(URL(string: "http://localhost:43210/chat/")))
        var replacementConnection = oldConnection
        replacementConnection.url = try XCTUnwrap(URL(string: "http://localhost:43210/changed/"))
        let barrier = HubWebsiteDataBarrier()
        var events: [String] = []
        var releasePurge: CheckedContinuation<Void, Never>?
        let old = HubConnectionSecurity(connection: oldConnection, bearerStorage: HubMemoryBearerStorage(),
                                        dataStore: .nonPersistent(), websiteDataBarrier: barrier,
                                        dataPurger: {
            events.append("purge-start")
            await withCheckedContinuation { releasePurge = $0 }
            events.append("purge-end")
        })
        let purge = Task { @MainActor in await old.clearData(epoch: old.epoch) }
        for _ in 0..<100 where releasePurge == nil { await Task.yield() }
        XCTAssertEqual(events, ["purge-start"])
        old.dispose(removeCredentials: false)

        let replacement = HubConnectionSecurity(connection: replacementConnection,
                                                  bearerStorage: HubMemoryBearerStorage(),
                                                  dataStore: .nonPersistent(), websiteDataBarrier: barrier,
                                                  cookieWriter: { _ in events.append("replacement-write") })
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .name: "term_llm_peer", .value: "capability", .domain: "localhost", .path: "/",
        ]))
        let write = Task { @MainActor in
            await replacement.saveCookies([cookie], epoch: replacement.epoch)
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(events, ["purge-start"], "replacement write must remain behind admitted old purge")

        releasePurge?.resume()
        _ = await purge.value
        let wrote = await write.value
        XCTAssertTrue(wrote)
        XCTAssertEqual(events, ["purge-start", "purge-end", "replacement-write"])
        replacement.dispose(removeCredentials: false)
    }

    @MainActor
    func testCatalogRejectsDuplicateLoopbackOriginAndCorruptHostKey() throws {
        let suite = "LinkedDevicesRuntimeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HubConnectionStore(defaults: defaults)
        _ = try store.saveLinkedDevices(name: "One", hostKey: Data(repeating: 1, count: 32), bridgePort: 43211)
        XCTAssertThrowsError(try store.saveLinkedDevices(name: "Two", hostKey: Data(repeating: 2, count: 32), bridgePort: 43211))
    }

    func testPeerSourceCannotOwnNativePushRoute() throws {
        let peer = HubConnection(id: UUID(), name: "Peer", kind: .directNode,
                                 url: try XCTUnwrap(URL(string: "http://localhost:43214/")),
                                 linkedDevicesHostKey: LinkedDevicesBase64URL.encode(Data(repeating: 8, count: 32)))
        XCTAssertNil(PushCenter.owningConnection(for: peer.url.appendingPathComponent("chat/1"),
                                                  in: [peer], selectedID: peer.id))
        XCTAssertNil(PushCenter.resolveDestination(peer.url.appendingPathComponent("chat/1"), scope: "/",
                                                    in: [peer], selectedID: peer.id))
    }

    func testApprovedOfflineEnrollmentPublishesOnlyAfterOriginReservation() async throws {
        let suite = "LinkedDevicesEnroll.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identities = LinkedDevicesIdentityStore(storage: LinkedDevicesMemoryStorage())
        let host = Data(repeating: 0x21, count: 32)
        var credential = LinkedDevicesCredential(hostKey: host, deviceSeed: Data(repeating: 0x22, count: 32))
        credential.deviceID = LinkedDevicesBase64URL.encode(Data(repeating: 0x23, count: 16))
        credential.reconnectCapability = Data(repeating: 0x24, count: 32)
        credential.brokerURL = try XCTUnwrap(URL(string: "https://broker.example"))
        credential.scope = "web-v1"
        credential.basePath = "/chat"
        credential.hostLabel = "Desk"
        try identities.save(credential)
        let catalog = HubConnectionStore(defaults: defaults)
        let listener = ControlledLoopbackListener()
        let runtime = LinkedDevicesRuntime(identities: identities, connector: nil,
                                           makeListener: { listener })
        let task = Task { @MainActor in
            try await runtime.enroll(.init(credential: credential, live: nil), fallbackName: "Linked host",
                                     in: catalog, token: UUID())
        }
        for _ in 0..<100 where !listener.started { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(listener.started)
        XCTAssertTrue(catalog.connections.isEmpty, "catalog must not publish before origin ownership")
        listener.resume(port: 43218)
        let source = try await task.value
        XCTAssertEqual(catalog.connections, [source])
        XCTAssertEqual(source.url.absoluteString, "http://localhost:43218/chat/")
        XCTAssertEqual(runtime.status(for: source.id), .offline)
    }

    func testConnectionLossDuringEnrollmentFinalizesApprovedGrantOffline() async throws {
        let suite = "LinkedDevicesEnrollLoss.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identities = LinkedDevicesIdentityStore(storage: LinkedDevicesMemoryStorage())
        let host = Data(repeating: 0x71, count: 32)
        var credential = LinkedDevicesCredential(hostKey: host, deviceSeed: Data(repeating: 0x72, count: 32))
        credential.deviceID = LinkedDevicesBase64URL.encode(Data(repeating: 0x73, count: 16))
        credential.reconnectCapability = Data(repeating: 0x74, count: 32)
        credential.brokerURL = try XCTUnwrap(URL(string: "https://broker.example"))
        credential.scope = "web-v1"
        credential.basePath = "/chat"
        try identities.save(credential)
        let catalog = HubConnectionStore(defaults: defaults)
        let listener = ControlledLoopbackListener()
        let runtime = LinkedDevicesRuntime(identities: identities, connector: nil, makeListener: { listener })
        let authorization = PeerAuthorizationState(PeerAuthorization(
            peerID: LinkedDevicesBase64URL.encode(host), sessionID: "first", expiresAt: .distantFuture,
            scopePrefix: "/chat"))
        let multiplexer = PeerHTTPMultiplexer(channel: RuntimeTestChannel())
        let live = LinkedDevicesLiveConnection(forwarder: multiplexer, authorization: authorization,
                                               stats: { PeerSessionStats() }, close: {
            multiplexer.close(); authorization.revoke()
        })
        let token = UUID()
        let task = Task { @MainActor in
            try await runtime.enroll(.init(credential: credential, live: live), fallbackName: "Desk",
                                     in: catalog, token: token)
        }
        for _ in 0..<100 where listener.startCount < 1 { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(listener.startCount, 1)

        authorization.revoke()
        runtime.pairingTransportClosed(hostKey: host, token: token)
        listener.resume(port: 43221)
        for _ in 0..<100 where listener.startCount < 2 { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(listener.startCount, 2, "dead first transport must be replaced by an offline bridge")
        listener.resume(port: 43222)

        let source = try await task.value
        XCTAssertEqual(catalog.connections, [source])
        XCTAssertEqual(source.url.absoluteString, "http://localhost:43222/chat/")
        XCTAssertEqual(runtime.status(for: source.id), .offline)
        XCTAssertNoThrow(try identities.load(hostKey: host))
    }

    func testEnrollmentRollbackPreservesLocalFailureAndExplainsRecovery() async throws {
        let suite = "LinkedDevicesEnrollFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identities = LinkedDevicesIdentityStore(storage: LinkedDevicesMemoryStorage())
        let host = Data(repeating: 0x61, count: 32)
        var credential = LinkedDevicesCredential(hostKey: host, deviceSeed: Data(repeating: 0x62, count: 32))
        credential.basePath = "/"
        try identities.save(credential)
        let catalog = HubConnectionStore(defaults: defaults)
        let runtime = LinkedDevicesRuntime(identities: identities, connector: nil,
                                           makeListener: { FailingEnrollmentListener() })
        do {
            _ = try await runtime.enroll(.init(credential: credential, live: nil), fallbackName: "Desk",
                                         in: catalog, token: UUID())
            XCTFail("Listener failure must reject enrollment")
        } catch let failure as LinkedDevicesPairingFailure {
            XCTAssertTrue(failure.enrollmentRolledBack)
            XCTAssertEqual(failure.stage, .startingLocalBridge)
            let message = failure.localizedDescription
            XCTAssertTrue(message.contains("POSIX 48"))
            XCTAssertTrue(message.contains("port is already in use"))
            XCTAssertTrue(message.contains("No connection was added"))
            XCTAssertTrue(message.contains("Revoke this incomplete device link"))
            XCTAssertFalse(message.contains("credentials have been kept"))
        }
        XCTAssertTrue(catalog.connections.isEmpty)
        XCTAssertThrowsError(try identities.load(hostKey: host))
    }

    func testOfflineEnrollmentWithRealLoopbackListener() async throws {
        let suite = "LinkedDevicesRealEnrollment.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identities = LinkedDevicesIdentityStore(storage: LinkedDevicesMemoryStorage())
        let host = Data(repeating: 0x63, count: 32)
        var credential = LinkedDevicesCredential(hostKey: host, deviceSeed: Data(repeating: 0x64, count: 32))
        credential.basePath = "/"
        try identities.save(credential)
        let catalog = HubConnectionStore(defaults: defaults)
        let runtime = LinkedDevicesRuntime(identities: identities, connector: nil)
        let source = try await runtime.enroll(.init(credential: credential, live: nil), fallbackName: "Desk",
                                             in: catalog, token: UUID())
        XCTAssertEqual(catalog.connections, [source])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(source.url.port), 1024)
        runtime.synchronize([])
    }

    func testHostControlledInvalidBasePathFailsWithoutConstructingURL() async throws {
        let suite = "LinkedDevicesInvalidPath.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identities = LinkedDevicesIdentityStore(storage: LinkedDevicesMemoryStorage())
        let host = Data(repeating: 0x79, count: 32)
        var credential = LinkedDevicesCredential(hostKey: host, deviceSeed: Data(repeating: 0x7A, count: 32))
        credential.basePath = "/host controlled space"
        let runtime = LinkedDevicesRuntime(identities: identities, connector: nil,
                                           makeListener: { ControlledLoopbackListener() })
        let catalog = HubConnectionStore(defaults: defaults)
        do {
            _ = try await runtime.enroll(
                .init(credential: credential, live: nil), fallbackName: "Desk", in: catalog, token: UUID())
            XCTFail("Invalid host base path must reject enrollment")
        } catch {}
        XCTAssertTrue(catalog.connections.isEmpty)
    }

    func testRemovingExistingSourceDuringRepairInvalidatesEnrollment() async throws {
        let suite = "LinkedDevicesEnrollRemoval.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identities = LinkedDevicesIdentityStore(storage: LinkedDevicesMemoryStorage())
        let host = Data(repeating: 0x75, count: 32)
        var credential = LinkedDevicesCredential(hostKey: host, deviceSeed: Data(repeating: 0x76, count: 32))
        credential.deviceID = LinkedDevicesBase64URL.encode(Data(repeating: 0x77, count: 16))
        credential.reconnectCapability = Data(repeating: 0x78, count: 32)
        credential.brokerURL = try XCTUnwrap(URL(string: "https://broker.example"))
        credential.scope = "web-v1"
        credential.basePath = "/changed"
        try identities.save(credential)
        let catalog = HubConnectionStore(defaults: defaults)
        let existing = try catalog.saveLinkedDevices(name: "Desk", hostKey: host,
                                                      bridgePort: 43223, basePath: "/chat")
        let listener = ControlledLoopbackListener()
        let runtime = LinkedDevicesRuntime(identities: identities, connector: nil, makeListener: { listener })
        runtime.synchronize([existing])
        let task = Task { @MainActor in
            try await runtime.enroll(.init(credential: credential, live: nil), fallbackName: "Desk",
                                     in: catalog, token: UUID())
        }
        for _ in 0..<100 where listener.startCount < 1 { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(listener.startCount, 1)

        catalog.remove(existing.id)
        runtime.synchronize(catalog.connections)
        listener.resume(port: 43223)
        do {
            _ = try await task.value
            XCTFail("Removing the source must invalidate in-flight enrollment")
        } catch {}

        XCTAssertTrue(catalog.connections.isEmpty, "removed source must not be recreated by late enrollment")
        XCTAssertNil(runtime.statuses[existing.id])
        XCTAssertThrowsError(try identities.load(hostKey: host))
    }

    func testLateAttachmentCannotResurrectRevokedSource() async throws {
        let suite = "LinkedDevicesRace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = LinkedDevicesMemoryStorage()
        let identities = LinkedDevicesIdentityStore(storage: storage)
        let host = Data(repeating: 0x31, count: 32)
        var credential = LinkedDevicesCredential(hostKey: host, deviceSeed: Data(repeating: 0x41, count: 32))
        credential.deviceID = LinkedDevicesBase64URL.encode(Data(repeating: 0x51, count: 16))
        credential.reconnectCapability = Data(repeating: 0x61, count: 32)
        credential.brokerURL = try XCTUnwrap(URL(string: "https://broker.example"))
        credential.scope = "web-v1"
        credential.basePath = "/chat"
        try identities.save(credential)
        let catalog = HubConnectionStore(defaults: defaults)
        let source = try catalog.saveLinkedDevices(name: "Desk", hostKey: host, bridgePort: 43219, basePath: "/chat")
        let listener = ControlledLoopbackListener()
        let connector = RuntimeTestConnector()
        let runtime = LinkedDevicesRuntime(identities: identities, connector: connector,
                                           makeListener: { listener })
        runtime.synchronize([source])
        for _ in 0..<100 where !listener.started { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(listener.started)

        runtime.markRevoked(source.id)
        listener.resume(port: 43219) // deliberately complete the stale await late
        for _ in 0..<100 where !connector.closed.value { try await Task.sleep(nanoseconds: 2_000_000) }

        XCTAssertEqual(runtime.status(for: source.id), .revoked)
        XCTAssertTrue(connector.closed.value)
        let transport = try XCTUnwrap(runtime.transport(for: source))
        do {
            _ = try await transport.execute(
                URLRequest(url: source.url.appendingPathComponent("v1/sessions")), onUnauthorized: nil)
            XCTFail("A revoked source must reject transport requests")
        } catch {}
    }

    func testReconnectBackoffIsBounded() {
        XCTAssertEqual(LinkedDevicesRuntime.backoffNanoseconds(attempt: 0), 1_000_000_000)
        XCTAssertEqual(LinkedDevicesRuntime.backoffNanoseconds(attempt: 5), 30_000_000_000)
        XCTAssertEqual(LinkedDevicesRuntime.backoffNanoseconds(attempt: 100), 30_000_000_000)
        XCTAssertTrue(LinkedDevicesRuntime.shouldStopAutomatically(LinkedDevicesBrokerError.superseded))
        XCTAssertTrue(LinkedDevicesRuntime.shouldStopAutomatically(LinkedDevicesBrokerError.quotaExceeded))
        XCTAssertFalse(LinkedDevicesRuntime.shouldStopAutomatically(LinkedDevicesBrokerError.notFound))
        XCTAssertFalse(LinkedDevicesRuntime.shouldStopAutomatically(LinkedDevicesBrokerError.peerOffline))
    }

    func testForegroundWakeCancelsExistingBackoffAndReconnectsImmediately() async throws {
        let connector = FailingRuntimeTestConnector()
        let (runtime, source) = try reconnectWakeFixture(connector: connector, seed: 0x52)
        runtime.synchronize([source])
        await connector.waitForAttempts(1)

        runtime.setForeground(false)
        runtime.setForeground(true)
        await connector.waitForAttempts(2)

        XCTAssertEqual(connector.attemptCount, 2)
        runtime.setForeground(false)
    }

    func testReachabilityWakeCancelsExistingBackoffAndReconnectsImmediately() async throws {
        let connector = FailingRuntimeTestConnector()
        let (runtime, source) = try reconnectWakeFixture(connector: connector, seed: 0x62)
        runtime.synchronize([source])
        await connector.waitForAttempts(1)

        runtime.networkChanged(false)
        runtime.networkChanged(true)
        await connector.waitForAttempts(2)

        XCTAssertEqual(connector.attemptCount, 2)
        runtime.setForeground(false)
    }

    private func reconnectWakeFixture(connector: FailingRuntimeTestConnector, seed: UInt8) throws
        -> (LinkedDevicesRuntime, HubConnection) {
        let identities = LinkedDevicesIdentityStore(storage: LinkedDevicesMemoryStorage())
        let host = Data(repeating: seed, count: 32)
        var credential = LinkedDevicesCredential(hostKey: host, deviceSeed: Data(repeating: seed &+ 1, count: 32))
        credential.deviceID = LinkedDevicesBase64URL.encode(Data(repeating: seed &+ 2, count: 16))
        credential.reconnectCapability = Data(repeating: seed &+ 3, count: 32)
        credential.brokerURL = try XCTUnwrap(URL(string: "https://broker.example"))
        credential.scope = "web-v1"
        credential.basePath = "/chat"
        try identities.save(credential)
        let source = HubConnection(id: UUID(), name: "Desk", kind: .directNode,
                                   url: try XCTUnwrap(URL(string: "http://localhost:43225/chat/")),
                                   needsKindReview: nil,
                                   linkedDevicesHostKey: LinkedDevicesBase64URL.encode(host))
        return (LinkedDevicesRuntime(identities: identities, connector: connector,
                                     makeListener: { ControlledLoopbackListener() }), source)
    }
}


private final class ImmediateLoopbackListener: PeerLoopbackListening, @unchecked Sendable {
    func start(port: UInt16?, onConnection: @escaping @Sendable (PeerByteStream) -> Void) async throws -> UInt16 {
        port ?? 43_300
    }
    func stop() {}
}

/// Hands out live connections; counts how many were made and closed.
private final class CountingRuntimeTestConnector: LinkedDevicesSessionConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var connects = 0
    private var closes = 0
    var connectCount: Int { lock.withLock { connects } }
    var closeCount: Int { lock.withLock { closes } }

    func reconnect(credential: LinkedDevicesCredential,
                   closed callback: @escaping @Sendable () -> Void) async throws -> LinkedDevicesLiveConnection {
        lock.withLock { connects += 1 }
        let authorization = PeerAuthorizationState(PeerAuthorization(
            peerID: LinkedDevicesBase64URL.encode(credential.hostKey), sessionID: UUID().uuidString,
            expiresAt: .distantFuture, scopePrefix: credential.basePath ?? "/"))
        let multiplexer = PeerHTTPMultiplexer(channel: RuntimeTestChannel())
        return LinkedDevicesLiveConnection(forwarder: multiplexer, authorization: authorization,
                                           stats: { PeerSessionStats() }, close: { [self] in
            lock.withLock { closes += 1 }
            multiplexer.close(); authorization.revoke(); callback()
        })
    }
}

@MainActor
private final class RuntimeTestClock {
    var now = ContinuousClock.now
}

/// Background lifecycle: podcast playback keeps the app running in the
/// background, where an open connection keeps the radio awake.
extension LinkedDevicesRuntimeTests {
    private func connectedRuntime(seed: UInt8, grace: Duration,
                                  clock: RuntimeTestClock? = nil) async throws
        -> (LinkedDevicesRuntime, CountingRuntimeTestConnector, HubConnection) {
        let identities = LinkedDevicesIdentityStore(storage: LinkedDevicesMemoryStorage())
        let host = Data(repeating: seed, count: 32)
        var credential = LinkedDevicesCredential(hostKey: host, deviceSeed: Data(repeating: seed &+ 1, count: 32))
        credential.deviceID = LinkedDevicesBase64URL.encode(Data(repeating: seed &+ 2, count: 16))
        credential.reconnectCapability = Data(repeating: seed &+ 3, count: 32)
        credential.brokerURL = try XCTUnwrap(URL(string: "https://broker.example"))
        credential.scope = "web-v1"
        credential.basePath = "/chat"
        try identities.save(credential)
        let source = HubConnection(id: UUID(), name: "Desk", kind: .directNode,
                                   url: try XCTUnwrap(URL(string: "http://localhost:\(43_300 + Int(seed))/chat/")),
                                   needsKindReview: nil, linkedDevicesHostKey: LinkedDevicesBase64URL.encode(host))
        let connector = CountingRuntimeTestConnector()
        let runtime = LinkedDevicesRuntime(identities: identities, connector: connector,
                                           makeListener: { ImmediateLoopbackListener() }, backgroundGrace: grace,
                                           now: { clock?.now ?? ContinuousClock.now })
        runtime.synchronize([source])
        try await waitUntil { runtime.status(for: source.id).isConnected }
        return (runtime, connector, source)
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testBackgroundClosesAnIdleConnectionAfterTheGraceAndReturningReconnects() async throws {
        let (runtime, connector, source) = try await connectedRuntime(seed: 0x81, grace: .milliseconds(50))
        defer { runtime.synchronize([]) }
        runtime.setForeground(false)
        XCTAssertTrue(runtime.status(for: source.id).isConnected, "a quick lock or app switch keeps the connection")
        XCTAssertEqual(connector.closeCount, 0)

        try await waitUntil { connector.closeCount == 1 }
        XCTAssertEqual(runtime.status(for: source.id), .suspended)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(connector.connectCount, 1, "nothing reconnects while the app is in the background")

        runtime.setForeground(true)
        try await waitUntil { runtime.status(for: source.id).isConnected }
        XCTAssertEqual(connector.connectCount, 2)
    }

    func testCapturingPageKeepsTheConnectionUntilItStops() async throws {
        let (runtime, connector, source) = try await connectedRuntime(seed: 0x82, grace: .milliseconds(50))
        defer { runtime.synchronize([]) }
        runtime.setMediaCaptureActive(true, for: source.id)
        runtime.setForeground(false)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(connector.closeCount, 0, "a Live call must keep working while the phone is locked")
        XCTAssertTrue(runtime.status(for: source.id).isConnected)

        runtime.setMediaCaptureActive(false, for: source.id)
        XCTAssertEqual(connector.closeCount, 0, "the grace starts when the call ends")
        try await waitUntil { connector.closeCount == 1 }
        XCTAssertEqual(runtime.status(for: source.id), .suspended)
    }

    func testReturningWithinTheGraceKeepsTheConnection() async throws {
        let clock = RuntimeTestClock()
        let (runtime, connector, source) = try await connectedRuntime(seed: 0x83, grace: .seconds(60), clock: clock)
        defer { runtime.synchronize([]) }
        runtime.setForeground(false)
        clock.now = clock.now + .seconds(59)
        runtime.setForeground(true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(connector.closeCount, 0)
        XCTAssertEqual(connector.connectCount, 1)
        XCTAssertTrue(runtime.status(for: source.id).isConnected)
    }

    func testReturningAfterTheGraceReplacesAConnectionTheAppWasSuspendedWith() async throws {
        let clock = RuntimeTestClock()
        let (runtime, connector, source) = try await connectedRuntime(seed: 0x84, grace: .seconds(60), clock: clock)
        defer { runtime.synchronize([]) }
        runtime.setForeground(false)
        // Suspended: the close is still waiting, but its time has passed.
        clock.now = clock.now + .seconds(61)
        runtime.setForeground(true)
        XCTAssertEqual(connector.closeCount, 1, "the host has most likely dropped it already")
        try await waitUntil { runtime.status(for: source.id).isConnected }
        XCTAssertEqual(connector.connectCount, 2)
    }

    func testBackgroundKeepsARevokedStatus() async throws {
        let (runtime, _, source) = try await connectedRuntime(seed: 0x85, grace: .milliseconds(50))
        defer { runtime.synchronize([]) }
        runtime.markRevoked(source.id)
        runtime.setForeground(false)
        XCTAssertEqual(runtime.status(for: source.id), .revoked)
        runtime.setForeground(true)
        XCTAssertEqual(runtime.status(for: source.id), .revoked)
    }
}
