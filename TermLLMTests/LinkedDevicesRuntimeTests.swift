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
        do { _ = try await identities.loadAsync(hostKey: host); XCTFail("Removed credential survived") }
        catch { XCTAssertEqual(error as? LinkedDevicesStorageError, .missing) }
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
    private var connectedHostKeys: [Data] = []
    var hostKeys: [Data] { lock.withLock { connectedHostKeys } }
    var connectCount: Int { lock.withLock { connects } }
    var closeCount: Int { lock.withLock { closes } }

    func reconnect(credential: LinkedDevicesCredential,
                   closed callback: @escaping @Sendable () -> Void) async throws -> LinkedDevicesLiveConnection {
        lock.withLock { connects += 1; connectedHostKeys.append(credential.hostKey) }
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
                                  clock: RuntimeTestClock? = nil,
                                  capabilityResolver: (@Sendable (any HubTransport, URL) async -> LinkedDevicesHostCapabilities?)? = nil) async throws
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
                                           now: { clock?.now ?? ContinuousClock.now },
                                           capabilityResolver: capabilityResolver ?? { _, _ in nil })
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

private final class GatedRuntimeCredentialStorage: LinkedDevicesSecureStorage, Sendable {
    let memory = LinkedDevicesMemoryStorage()
    let gate = CredentialReadGate()
    private let failingAccount: String?
    init(failingHostKey: Data? = nil) {
        failingAccount = failingHostKey.map { LinkedDevicesIdentityStore.account(hostKey: $0) }
    }
    func read(account: String) throws -> Data? {
        let snapshot = try memory.read(account: account)
        gate.read()
        if account == failingAccount { throw LinkedDevicesStorageError.unavailable(-1) }
        return snapshot
    }
    func write(_ data: Data, account: String) throws { try memory.write(data, account: account) }
    func delete(account: String) throws { try memory.delete(account: account) }
}

extension LinkedDevicesRuntimeTests {
    private func credentialSource(_ identities: LinkedDevicesIdentityStore, seed: UInt8) throws -> HubConnection {
        let host = Data(repeating: seed, count: 32)
        var credential = LinkedDevicesCredential(hostKey: host, deviceSeed: Data(repeating: seed &+ 1, count: 32))
        credential.basePath = "/chat"
        try identities.save(credential)
        return HubConnection(id: UUID(), name: "Peer", kind: .directNode,
                             url: try XCTUnwrap(URL(string: "http://localhost:\(44_000 + Int(seed))/chat/")),
                             linkedDevicesHostKey: LinkedDevicesBase64URL.encode(host))
    }

    func testForegroundReservesSeveralStartsAndReadsCredentialsOffMainThread() async throws {
        let storage = GatedRuntimeCredentialStorage()
        let identities = LinkedDevicesIdentityStore(storage: storage)
        let sources = try [UInt8(0x91), 0x92, 0x93].map { try credentialSource(identities, seed: $0) }
        let connector = CountingRuntimeTestConnector()
        let runtime = LinkedDevicesRuntime(identities: identities, connector: connector,
                                           makeListener: { ImmediateLoopbackListener() })
        defer { storage.gate.resume(); runtime.synchronize([]) }
        runtime.setForeground(false)
        runtime.synchronize(sources)
        XCTAssertEqual(storage.gate.readCount, 0)
        storage.gate.pause()
        runtime.setForeground(true)
        XCTAssertTrue(sources.allSatisfy { runtime.status(for: $0.id) == .connecting })
        try await waitUntil { storage.gate.readCount == 1 }
        // MainActor is responsive while storage is blocked, and reentrant
        // lifecycle/catalog callbacks cannot submit duplicate attempts.
        runtime.synchronize(sources)
        runtime.setForeground(true)
        XCTAssertEqual(connector.connectCount, 0)
        storage.gate.resume()
        try await waitUntil { sources.allSatisfy { runtime.status(for: $0.id).isConnected } }
        XCTAssertEqual(storage.gate.mainThreadReadCount, 0)
        XCTAssertEqual(storage.gate.readCount, sources.count)
        XCTAssertEqual(connector.connectCount, sources.count)
        XCTAssertEqual(Set(connector.hostKeys), Set([UInt8(0x91), 0x92, 0x93].map { Data(repeating: $0, count: 32) }))
    }

    func testRemovalDuringCredentialLoadCannotConnectAndDoesNotWaitForStorageLock() async throws {
        let storage = GatedRuntimeCredentialStorage()
        let identities = LinkedDevicesIdentityStore(storage: storage)
        let source = try credentialSource(identities, seed: 0x94)
        let connector = CountingRuntimeTestConnector()
        let runtime = LinkedDevicesRuntime(identities: identities, connector: connector)
        defer { storage.gate.resume() }
        storage.gate.pause()
        runtime.synchronize([source])
        try await waitUntil { storage.gate.readCount == 1 }
        runtime.synchronize([])
        XCTAssertNil(runtime.statuses[source.id])
        storage.gate.resume()
        // This queued load drains the earlier removal, proving deletion as well
        // as immediate invalidation without ever waiting on the lock on main.
        let host = try XCTUnwrap(LinkedDevicesBase64URL.decode(source.linkedDevicesHostKey!))
        do { _ = try await identities.loadAsync(hostKey: host); XCTFail("Removed credential survived") }
        catch { XCTAssertEqual(error as? LinkedDevicesStorageError, .missing) }
        XCTAssertEqual(connector.connectCount, 0)
        XCTAssertEqual(storage.gate.mainThreadReadCount, 0)
    }

    func testHostIdentityChangeDuringCredentialLoadRejectsStaleCredential() async throws {
        let storage = GatedRuntimeCredentialStorage()
        let identities = LinkedDevicesIdentityStore(storage: storage)
        let source = try credentialSource(identities, seed: 0x95)
        let connector = CountingRuntimeTestConnector()
        let runtime = LinkedDevicesRuntime(identities: identities, connector: connector)
        defer { storage.gate.resume(); runtime.synchronize([]) }
        storage.gate.pause()
        runtime.synchronize([source])
        try await waitUntil { storage.gate.readCount == 1 }
        var changed = source
        changed.linkedDevicesHostKey = LinkedDevicesBase64URL.encode(Data(repeating: 0x96, count: 32))
        runtime.synchronize([changed])
        storage.gate.resume()
        let host = try XCTUnwrap(LinkedDevicesBase64URL.decode(source.linkedDevicesHostKey!))
        _ = try await identities.loadAsync(hostKey: host)
        XCTAssertEqual(runtime.status(for: source.id), .identityChanged)
        XCTAssertEqual(connector.connectCount, 0)
    }

    func testBackgroundDuringCredentialLoadCancelsStart() async throws {
        let storage = GatedRuntimeCredentialStorage()
        let identities = LinkedDevicesIdentityStore(storage: storage)
        let source = try credentialSource(identities, seed: 0x97)
        let connector = CountingRuntimeTestConnector()
        let runtime = LinkedDevicesRuntime(identities: identities, connector: connector)
        defer { storage.gate.resume(); runtime.synchronize([]) }
        storage.gate.pause()
        runtime.synchronize([source])
        try await waitUntil { storage.gate.readCount == 1 }
        runtime.setForeground(false)
        storage.gate.resume()
        let host = try XCTUnwrap(LinkedDevicesBase64URL.decode(source.linkedDevicesHostKey!))
        _ = try await identities.loadAsync(hostKey: host)
        XCTAssertEqual(runtime.status(for: source.id), .suspended)
        XCTAssertEqual(connector.connectCount, 0)
    }

    func testForegroundAgainWhileOldCredentialLoadIsPendingOnlyConnectsNewAttempt() async throws {
        let storage = GatedRuntimeCredentialStorage()
        let identities = LinkedDevicesIdentityStore(storage: storage)
        let source = try credentialSource(identities, seed: 0x98)
        let connector = CountingRuntimeTestConnector()
        let runtime = LinkedDevicesRuntime(identities: identities, connector: connector,
                                           makeListener: { ImmediateLoopbackListener() })
        defer { storage.gate.resume(); runtime.synchronize([]) }
        storage.gate.pause()
        runtime.synchronize([source])
        try await waitUntil { storage.gate.readCount == 1 }
        runtime.setForeground(false)
        runtime.setForeground(true)
        storage.gate.releaseOne()
        try await waitUntil { storage.gate.readCount == 2 }
        XCTAssertEqual(connector.connectCount, 0, "the retired read cannot start the old attempt")
        storage.gate.resume()
        try await waitUntil { runtime.status(for: source.id).isConnected }
        XCTAssertEqual(connector.connectCount, 1)
    }

    func testEndpointChangeDuringCredentialLoadRetiresOldAttempt() async throws {
        let storage = GatedRuntimeCredentialStorage()
        let identities = LinkedDevicesIdentityStore(storage: storage)
        let source = try credentialSource(identities, seed: 0x9D)
        let connector = CountingRuntimeTestConnector()
        let runtime = LinkedDevicesRuntime(identities: identities, connector: connector,
                                           makeListener: { ImmediateLoopbackListener() })
        defer { storage.gate.resume(); runtime.synchronize([]) }
        storage.gate.pause()
        runtime.synchronize([source])
        try await waitUntil { storage.gate.readCount == 1 }
        var changed = source
        changed.url = try XCTUnwrap(URL(string: "http://localhost:44999/chat/"))
        runtime.synchronize([changed])
        storage.gate.releaseOne()
        try await waitUntil { storage.gate.readCount == 2 }
        XCTAssertEqual(connector.connectCount, 0, "the retired endpoint cannot use a late credential")
        storage.gate.resume()
        try await waitUntil { runtime.status(for: source.id).isConnected }
        XCTAssertEqual(connector.connectCount, 1)
    }

    func testMissingCorruptAndFailedCredentialsFailClosedWithoutBorrowingAnotherSource() async throws {
        let storage = GatedRuntimeCredentialStorage(failingHostKey: Data(repeating: 0x9C, count: 32))
        let identities = LinkedDevicesIdentityStore(storage: storage)
        let valid = try credentialSource(identities, seed: 0x99)
        let missing = try credentialSource(identities, seed: 0x9A)
        let corrupt = try credentialSource(identities, seed: 0x9B)
        let failed = try credentialSource(identities, seed: 0x9C)
        try identities.remove(hostKey: Data(repeating: 0x9A, count: 32))
        try storage.write(Data("invalid".utf8), account: LinkedDevicesIdentityStore.account(hostKey: Data(repeating: 0x9B, count: 32)))
        let connector = CountingRuntimeTestConnector()
        let runtime = LinkedDevicesRuntime(identities: identities, connector: connector,
                                           makeListener: { ImmediateLoopbackListener() })
        defer { runtime.synchronize([]) }
        runtime.synchronize([valid, missing, corrupt, failed])
        try await waitUntil {
            runtime.status(for: valid.id).isConnected &&
            runtime.status(for: missing.id) != .connecting && runtime.status(for: corrupt.id) != .connecting &&
            runtime.status(for: failed.id) != .connecting
        }
        XCTAssertEqual(connector.connectCount, 1)
        XCTAssertEqual(runtime.status(for: missing.id), .failed(LinkedDevicesRuntime.safeMessage(LinkedDevicesStorageError.missing)))
        XCTAssertEqual(runtime.status(for: corrupt.id), .failed(LinkedDevicesRuntime.safeMessage(LinkedDevicesStorageError.corrupt)))
        XCTAssertEqual(runtime.status(for: failed.id), .failed(LinkedDevicesRuntime.safeMessage(LinkedDevicesStorageError.unavailable(-1))))
        XCTAssertEqual(connector.hostKeys, [Data(repeating: 0x99, count: 32)])
        XCTAssertEqual(storage.gate.mainThreadReadCount, 0)
    }
}

extension LinkedDevicesRuntimeTests {
    func testOwnedButIneligibleCredentialCompletionReleasesReservationAndCanRestart() async throws {
        for change in ["url", "kind", "host", "cancelled"] {
            let storage = GatedRuntimeCredentialStorage()
            let identities = LinkedDevicesIdentityStore(storage: storage)
            let source = try credentialSource(identities, seed: 0xA1)
            let connector = CountingRuntimeTestConnector()
            let runtime = LinkedDevicesRuntime(identities: identities, connector: connector,
                                               makeListener: { ImmediateLoopbackListener() })
            storage.gate.pause()
            defer { storage.gate.resume(); runtime.synchronize([]) }
            runtime.synchronize([source])
            try await waitUntil { storage.gate.readCount == 1 }
            let token = try XCTUnwrap(runtime.pendingStartToken(for: source.id))
            // Deliver an owned completion whose captured source snapshot no
            // longer matches, without another lifecycle callback clearing it.
            var expected = source
            switch change {
            case "url": expected.url = try XCTUnwrap(URL(string: "http://localhost:44998/changed/"))
            case "kind": expected.kind = .hub
            case "host": expected.linkedDevicesHostKey = LinkedDevicesBase64URL.encode(Data(repeating: 0xA2, count: 32))
            default: break
            }
            XCTAssertFalse(runtime.revalidatePendingStart(sourceID: source.id, token: token, expected: expected,
                                                          cancelled: change == "cancelled"), change)
            XCTAssertNil(runtime.pendingStartToken(for: source.id), change)
            XCTAssertEqual(runtime.status(for: source.id), .offline, change)
            XCTAssertEqual(connector.connectCount, 0)
            runtime.synchronize([source])
            let replacement = try XCTUnwrap(runtime.pendingStartToken(for: source.id))
            XCTAssertNotEqual(replacement, token)
            XCTAssertFalse(runtime.revalidatePendingStart(sourceID: source.id, token: token, expected: expected,
                                                          cancelled: false))
            XCTAssertEqual(runtime.pendingStartToken(for: source.id), replacement,
                           "A stale callback cannot clear the replacement reservation")
            storage.gate.resume()
            try await waitUntil { runtime.status(for: source.id).isConnected }
            XCTAssertEqual(connector.connectCount, 1)
        }
    }
}

/// Linked device tools: the host's `GET /v1/capabilities` answer is the only
/// thing that can enable the WebMCP bridge for a linked source.
extension LinkedDevicesRuntimeTests {
    private func capabilities(_ json: String) -> LinkedDevicesHostCapabilities {
        LinkedDevicesHostCapabilities.parse(Data(json.utf8))
    }

    func testCapabilityParsingRequiresTheLiteralTrueAtTheDocumentedPath() {
        XCTAssertTrue(capabilities(#"{"linked_devices":{"active":true,"device_tools":true}}"#).deviceTools)
        XCTAssertTrue(capabilities(#"{"other":1,"linked_devices":{"device_tools":true,"future":{"x":[1]}}}"#).deviceTools,
                      "unknown fields are ignored")
        for body in [
            #"{"linked_devices":{"active":true,"device_tools":false}}"#,
            #"{"linked_devices":{"active":true}}"#,
            #"{"linked_devices":{"device_tools":1}}"#,
            #"{"linked_devices":{"device_tools":"true"}}"#,
            #"{"linked_devices":{"device_tools":null}}"#,
            #"{"linked_devices":{"device_tools":[true]}}"#,
            #"{"linked_devices":true}"#,
            #"{"linked_devices":[{"device_tools":true}]}"#,
            #"{"device_tools":true}"#,
            #"{"device_tools":true,"linked_devices":{}}"#,
            #"{"capabilities":{"linked_devices":{"device_tools":true}}}"#,
            #"[{"linked_devices":{"device_tools":true}}]"#,
            #"true"#, #"null"#, #"{"#, "",
        ] {
            XCTAssertFalse(capabilities(body).deviceTools, body)
        }
        let padding = String(repeating: " ", count: LinkedDevicesHostCapabilities.maximumResponseBytes)
        XCTAssertFalse(capabilities(#"{"linked_devices":{"device_tools":true}}"# + padding).deviceTools,
                       "an oversized answer is not trusted")
    }

    func testCapabilityRequestIsOriginRelativeToTheAdvertisedMountWithoutCredentials() throws {
        for (mount, path) in [("http://localhost:43300/chat/", "/chat/v1/capabilities"),
                              ("http://localhost:43300/", "/v1/capabilities"),
                              ("http://localhost:43300/a/b/?x=1#y", "/a/b/v1/capabilities")] {
            let request = try XCTUnwrap(LinkedDevicesHostCapabilities.request(mount: XCTUnwrap(URL(string: mount))))
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "http://localhost:43300" + path, mount)
            XCTAssertEqual(request.allHTTPHeaderFields, ["Accept": "application/json"])
            XCTAssertNil(request.httpBody)
        }
    }

    private func transport(_ forwarder: CapabilityStubForwarder, mount: URL) -> WebRTCHubTransport {
        let authorization = PeerAuthorizationState(PeerAuthorization(
            peerID: "host", sessionID: "session", expiresAt: .distantFuture, scopePrefix: "/chat"))
        return WebRTCHubTransport(forwarder: forwarder, authorization: authorization, hubBaseURL: mount)
    }

    func testCapabilityProbeUsesOnlyThePinnedTransportAndTheMountedPath() async throws {
        let mount = try XCTUnwrap(URL(string: "http://localhost:43300/chat/"))
        let forwarder = CapabilityStubForwarder { _ in
            (200, Data(#"{"linked_devices":{"active":true,"device_tools":true}}"#.utf8))
        }
        let result = await LinkedDevicesHostCapabilities.resolve(over: transport(forwarder, mount: mount), mount: mount,
                                                                 retryDelays: [])
        XCTAssertEqual(result, LinkedDevicesHostCapabilities(deviceTools: true))
        let request = try XCTUnwrap(forwarder.requests.first)
        XCTAssertEqual(forwarder.requests.count, 1)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/chat/v1/capabilities")
        XCTAssertTrue(request.body.isEmpty)
        for name in ["Cookie", "Authorization", "Origin"] {
            XCTAssertTrue(request.header.values(name).isEmpty, name)
        }
    }

    func testCapabilityProbeTreatsAnswersAsDefinitiveAndOnlyRetriesTransportFailures() async throws {
        let mount = try XCTUnwrap(URL(string: "http://localhost:43300/chat/"))
        let yes = Data(#"{"linked_devices":{"device_tools":true}}"#.utf8)
        func run(_ respond: @escaping @Sendable (Int) throws -> (Int, Data)) async
            -> (LinkedDevicesHostCapabilities?, Int) {
            let forwarder = CapabilityStubForwarder(respond)
            let result = await LinkedDevicesHostCapabilities.resolve(
                over: transport(forwarder, mount: mount), mount: mount, retryDelays: [.milliseconds(1)])
            return (result, forwarder.requests.count)
        }
        // An older host (404), a scope denial (403) and a non-true answer end the probe at once.
        let notFound = await run { _ in (404, Data("not found".utf8)) }
        XCTAssertEqual(notFound.0, .unsupported)
        XCTAssertEqual(notFound.1, 1)
        let denied = await run { _ in (403, Data()) }
        XCTAssertEqual(denied.0, .unsupported)
        XCTAssertEqual(denied.1, 1)
        let notTrue = await run { _ in (200, Data(#"{"linked_devices":{"device_tools":"true"}}"#.utf8)) }
        XCTAssertEqual(notTrue.0, .unsupported)
        XCTAssertEqual(notTrue.1, 1)
        let garbage = await run { _ in (200, Data("<html>".utf8)) }
        XCTAssertEqual(garbage.0, .unsupported)
        // A server error is retried once and the later answer wins.
        let recovered = await run { attempt in attempt == 1 ? (503, Data()) : (200, yes) }
        XCTAssertEqual(recovered.0, LinkedDevicesHostCapabilities(deviceTools: true))
        XCTAssertEqual(recovered.1, 2)
        // No answer at all is "unknown", never a grant.
        let unreachable = await run { _ in throw LinkedDevicesUnavailable(message: "offline") }
        XCTAssertNil(unreachable.0)
        XCTAssertEqual(unreachable.1, 2)
    }

    func testRuntimeDoesNotAdvertiseDeviceToolsUntilTheHostSaysSo() async throws {
        let (runtime, _, source) = try await connectedRuntime(seed: 0x90, grace: .seconds(60))
        defer { runtime.synchronize([]) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(runtime.advertisesDeviceTools(for: source.id), "connected alone enables nothing")
        XCTAssertFalse(runtime.advertisesDeviceTools(for: UUID()))
    }

    func testAdvertisementFollowsEachVerifiedConnectionAndIsDroppedOnRevocation() async throws {
        let resolver = ScriptedCapabilityResolver(answers: [
            LinkedDevicesHostCapabilities(deviceTools: true), nil, .unsupported, LinkedDevicesHostCapabilities(deviceTools: true),
        ])
        let (runtime, _, source) = try await connectedRuntime(
            seed: 0x91, grace: .seconds(60), capabilityResolver: { await resolver.resolve($0, $1) })
        defer { runtime.synchronize([]) }
        try await waitUntil { runtime.advertisesDeviceTools(for: source.id) }
        XCTAssertEqual(resolver.mounts, [source.url], "asked over the source's own mount")

        // A connection that gets no answer (the host may have been downgraded) has no tools.
        runtime.reconnectNow(source.id)
        try await waitUntil { resolver.callCount == 2 && runtime.status(for: source.id).isConnected }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(runtime.advertisesDeviceTools(for: source.id), "no answer must not inherit the earlier true")

        // A definitive "no" stays no.
        runtime.reconnectNow(source.id)
        try await waitUntil { resolver.callCount == 3 && runtime.status(for: source.id).isConnected }
        XCTAssertFalse(runtime.advertisesDeviceTools(for: source.id))

        runtime.reconnectNow(source.id)
        try await waitUntil { runtime.advertisesDeviceTools(for: source.id) }
        runtime.markRevoked(source.id)
        XCTAssertFalse(runtime.advertisesDeviceTools(for: source.id), "revoked access never keeps tools")
        XCTAssertEqual(runtime.status(for: source.id), .revoked)
    }

    func testSameHostFlagSurvivesOfflineButAFreshAttachMustEarnItAgain() async throws {
        let resolver = ScriptedCapabilityResolver(
            answers: [LinkedDevicesHostCapabilities(deviceTools: true), LinkedDevicesHostCapabilities(deviceTools: true)],
            holdIndex: 2)
        let (runtime, _, source) = try await connectedRuntime(
            seed: 0x94, grace: .milliseconds(30), capabilityResolver: { await resolver.resolve($0, $1) })
        defer { runtime.synchronize([]) }
        try await waitUntil { runtime.advertisesDeviceTools(for: source.id) }

        // Backgrounding closes the connection; the pinned host's flag is kept while offline.
        runtime.setForeground(false)
        try await waitUntil { runtime.status(for: source.id) == .suspended }
        XCTAssertTrue(runtime.advertisesDeviceTools(for: source.id))

        // The new connection goes live without it until the host answers again.
        runtime.setForeground(true)
        try await waitUntil { resolver.callCount == 2 && runtime.status(for: source.id).isConnected }
        XCTAssertFalse(runtime.advertisesDeviceTools(for: source.id), "unverified while the reply is pending")
        resolver.release()
        try await waitUntil { runtime.advertisesDeviceTools(for: source.id) }
    }

    func testStaleCapabilityAnswerCannotApplyToAReplacementConnection() async throws {
        let resolver = ScriptedCapabilityResolver(
            answers: [LinkedDevicesHostCapabilities(deviceTools: true), .unsupported], holdIndex: 1)
        let (runtime, _, source) = try await connectedRuntime(
            seed: 0x92, grace: .seconds(60), capabilityResolver: { await resolver.resolve($0, $1) })
        defer { runtime.synchronize([]) }
        try await waitUntil { resolver.callCount == 1 }
        runtime.reconnectNow(source.id)
        try await waitUntil { resolver.callCount == 2 && runtime.status(for: source.id).isConnected }
        resolver.release()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(runtime.advertisesDeviceTools(for: source.id),
                       "the retired connection's late true must not enable tools")
    }

    func testRemovingTheSourceDropsItsAdvertisement() async throws {
        let resolver = ScriptedCapabilityResolver(answers: [LinkedDevicesHostCapabilities(deviceTools: true)])
        let (runtime, _, source) = try await connectedRuntime(
            seed: 0x93, grace: .seconds(60), capabilityResolver: { await resolver.resolve($0, $1) })
        try await waitUntil { runtime.advertisesDeviceTools(for: source.id) }
        runtime.synchronize([])
        XCTAssertFalse(runtime.advertisesDeviceTools(for: source.id))
        XCTAssertNil(runtime.capabilities[source.id])
    }
}

private final class ScriptedCapabilityResolver: @unchecked Sendable {
    private let lock = NSLock()
    private let answers: [LinkedDevicesHostCapabilities?]
    private let holdIndex: Int?
    private var calls: [URL] = []
    private var released = false

    init(answers: [LinkedDevicesHostCapabilities?], holdIndex: Int? = nil) {
        self.answers = answers
        self.holdIndex = holdIndex
    }

    var callCount: Int { lock.withLock { calls.count } }
    var mounts: [URL] { lock.withLock { calls } }
    func release() { lock.withLock { released = true } }

    func resolve(_ transport: any HubTransport, _ mount: URL) async -> LinkedDevicesHostCapabilities? {
        let index = lock.withLock { calls.append(mount); return calls.count }
        if index == holdIndex {
            while !lock.withLock({ released }) { try? await Task.sleep(for: .milliseconds(5)) }
        }
        return answers[min(index, answers.count) - 1]
    }
}

private final class CapabilityStubForwarder: PeerHTTPForwarding, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [PeerHTTPRequest] = []
    private let respond: @Sendable (Int) throws -> (Int, Data)

    init(_ respond: @escaping @Sendable (Int) throws -> (Int, Data)) { self.respond = respond }

    var requests: [PeerHTTPRequest] { lock.withLock { seen } }

    func forward(_ request: PeerHTTPRequest, headTimeout: TimeInterval?) async throws -> PeerHTTPResponse {
        let attempt = lock.withLock { seen.append(request); return seen.count }
        let (status, body) = try respond(attempt)
        return PeerHTTPResponse(status: status, header: PeerHeader(), body: .fixed([body]), cancel: {})
    }
}
