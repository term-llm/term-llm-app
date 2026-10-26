import XCTest
@testable import TermLLM

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

private final class ControlledLoopbackListener: PeerLoopbackListening, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    private var starts = 0
    private(set) var stopped = false
    var started: Bool { lock.withLock { continuation != nil } }
    var startCount: Int { lock.withLock { starts } }

    func start(port: UInt16?, onConnection: @escaping @Sendable (PeerByteStream) -> Void) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                starts += 1
                self.continuation = continuation
            }
        }
    }

    func resume(port: UInt16) {
        let continuation = lock.withLock { let value = self.continuation; self.continuation = nil; return value }
        continuation?.resume(returning: port)
    }

    func stop() { lock.withLock { stopped = true } }
}

private final class RuntimeTestChannel: PeerFrameChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var closeHandler: (() -> Void)?
    var isOpen: Bool { true }
    var bufferedAmount: UInt64 { 0 }
    func send(_ message: Data) -> Bool { true }
    func close() { lock.withLock { closeHandler }?() }
    func setHandlers(onMessage: @escaping (Data) -> Void, onClose: @escaping () -> Void,
                     onBufferedAmountChange: @escaping () -> Void) {
        lock.withLock { closeHandler = onClose }
    }
}

private final class BackpressuredRuntimeTestChannel: PeerFrameChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var closeHandler: (() -> Void)?
    private var sends = 0
    var isOpen: Bool { true }
    var bufferedAmount: UInt64 { PeerWireLimits.default.sendHighWaterBytes + 1 }
    var sendCount: Int { lock.withLock { sends } }
    func send(_ message: Data) -> Bool { lock.withLock { sends += 1 }; return true }
    func close() { lock.withLock { closeHandler }?() }
    func setHandlers(onMessage: @escaping (Data) -> Void, onClose: @escaping () -> Void,
                     onBufferedAmountChange: @escaping () -> Void) {
        lock.withLock { closeHandler = onClose }
    }
}

private final class ControlledRuntimeTestChannel: PeerFrameChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    private var messages: [Data] = []
    private var sentWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var messageHandler: ((Data) -> Void)?
    private var closeHandler: (() -> Void)?

    var isOpen: Bool { lock.withLock { open } }
    var bufferedAmount: UInt64 { 0 }
    var sentFrames: [PeerFrame] {
        lock.withLock { messages }.compactMap { try? PeerFrameCodec.decode($0) }
    }

    func send(_ message: Data) -> Bool {
        let outcome: (Bool, [CheckedContinuation<Void, Never>]) = lock.withLock {
            guard open else { return (false, []) }
            messages.append(message)
            let ready = sentWaiters.filter { $0.0 <= messages.count }.map { $0.1 }
            sentWaiters.removeAll { $0.0 <= messages.count }
            return (true, ready)
        }
        outcome.1.forEach { $0.resume() }
        return outcome.0
    }

    func waitForSentFrames(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let ready: Bool = lock.withLock {
                if messages.count >= count { return true }
                sentWaiters.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func close() { remoteClose() }

    func setHandlers(onMessage: @escaping (Data) -> Void, onClose: @escaping () -> Void,
                     onBufferedAmountChange: @escaping () -> Void) {
        lock.withLock {
            messageHandler = onMessage
            closeHandler = onClose
        }
    }

    func deliver(_ frame: PeerFrame, limits: PeerWireLimits = .default) throws {
        let handler = lock.withLock { messageHandler }
        handler?(try PeerFrameCodec.encode(frame, limits: limits))
    }

    func remoteClose() {
        let handler: (() -> Void)? = lock.withLock {
            guard open else { return nil }
            open = false
            return closeHandler
        }
        handler?()
    }
}

private final class FailingRuntimeTestConnector: LinkedDevicesSessionConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    var attemptCount: Int { lock.withLock { attempts } }

    func reconnect(credential: LinkedDevicesCredential,
                   closed callback: @escaping @Sendable () -> Void) async throws -> LinkedDevicesLiveConnection {
        let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
            attempts += 1
            let ready = waiters.filter { $0.0 <= attempts }.map { $0.1 }
            waiters.removeAll { $0.0 <= attempts }
            return ready
        }
        ready.forEach { $0.resume() }
        throw LinkedDevicesUnavailable(message: "controlled reconnect failure")
    }

    func waitForAttempts(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let ready: Bool = lock.withLock {
                if attempts >= count { return true }
                waiters.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }
}

private final class RuntimeTestConnector: LinkedDevicesSessionConnecting, @unchecked Sendable {
    let closed = LockedFlag()
    func reconnect(credential: LinkedDevicesCredential,
                   closed callback: @escaping @Sendable () -> Void) async throws -> LinkedDevicesLiveConnection {
        let authorization = PeerAuthorizationState(PeerAuthorization(
            peerID: LinkedDevicesBase64URL.encode(credential.hostKey), sessionID: UUID().uuidString,
            expiresAt: .distantFuture, scopePrefix: credential.basePath ?? "/"))
        let multiplexer = PeerHTTPMultiplexer(channel: RuntimeTestChannel())
        let closedFlag = closed
        return LinkedDevicesLiveConnection(forwarder: multiplexer, authorization: authorization,
                                           stats: { PeerSessionStats() }, close: {
            closedFlag.set(); multiplexer.close(); authorization.revoke(); callback()
        })
    }
}

private final class DelayedLinkedDevicesForwarder: PeerHTTPForwarding, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PeerHTTPResponse, Never>?
    private let status: Int
    init(status: Int = 200) { self.status = status }
    var started: Bool { lock.withLock { continuation != nil } }
    func forward(_ request: PeerHTTPRequest, headTimeout: TimeInterval?) async throws -> PeerHTTPResponse {
        await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }
    func finish() {
        let continuation = lock.withLock { let value = self.continuation; self.continuation = nil; return value }
        continuation?.resume(returning: PeerHTTPResponse(status: status, header: PeerHeader(),
                                                         body: .fixed([Data("ok".utf8)]), cancel: {}))
    }
}

private final class ConcurrentDelayedLinkedDevicesForwarder: PeerHTTPForwarding, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<PeerHTTPResponse, Never>] = []
    private var requests: [PeerHTTPRequest] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    var dispatchCount: Int { lock.withLock { requests.count } }
    var methods: [String] { lock.withLock { requests.map(\.method) } }

    func forward(_ request: PeerHTTPRequest, headTimeout: TimeInterval?) async throws -> PeerHTTPResponse {
        await withCheckedContinuation { continuation in
            let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
                requests.append(request)
                continuations.append(continuation)
                let ready = waiters.filter { $0.0 <= requests.count }.map { $0.1 }
                waiters.removeAll { $0.0 <= requests.count }
                return ready
            }
            ready.forEach { $0.resume() }
        }
    }

    func waitForDispatches(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let ready: Bool = lock.withLock {
                if requests.count >= count { return true }
                waiters.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func finishAll(status: Int = 200, body: Data = Data("old".utf8)) {
        let pending = lock.withLock { let value = continuations; continuations.removeAll(); return value }
        for continuation in pending {
            continuation.resume(returning: PeerHTTPResponse(status: status, header: PeerHeader(),
                                                             body: .fixed([body]), cancel: {}))
        }
    }
}

private final class ProductionStaleAuthorizationForwarder: PeerHTTPForwarding, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PeerHTTPResponse, Never>?
    var started: Bool { lock.withLock { continuation != nil } }

    func forward(_ request: PeerHTTPRequest, headTimeout: TimeInterval?) async throws -> PeerHTTPResponse {
        if request.path.contains("/v1/sessions/status") {
            return await withCheckedContinuation { continuation in
                lock.withLock { self.continuation = continuation }
            }
        }
        return PeerHTTPResponse(status: 500, header: PeerHeader(),
                                body: .fixed([Data("{}".utf8)]), cancel: {})
    }

    func finishUnauthorized() {
        let continuation = lock.withLock { let value = self.continuation; self.continuation = nil; return value }
        continuation?.resume(returning: PeerHTTPResponse(status: 401, header: PeerHeader(),
                                                         body: .fixed([Data("{\"message\":\"old\"}".utf8)]),
                                                         cancel: {}))
    }
}

private final class MemoryPeerByteStream: PeerByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [Data?]
    private(set) var closed = false
    private var output = Data()
    init(input: Data) { reads = [input, nil] }
    func read(maxLength: Int) async throws -> Data? {
        lock.withLock { reads.isEmpty ? nil : reads.removeFirst() }
    }
    func write(_ data: Data) async throws { lock.withLock { output.append(data) } }
    func close() { lock.withLock { closed = true } }
    var written: Data { lock.withLock { output } }
}

private final class LinkedDevicesForwarder: PeerHTTPForwarding, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPaths: [String] = []
    let status: Int
    let chunks: [Data]
    let bodyError: Error?
    let contentType: String
    init(status: Int = 200, chunks: [Data] = [Data("{\"ok\":true}".utf8)],
         bodyError: Error? = nil, contentType: String = "application/json") {
        self.status = status
        self.chunks = chunks
        self.bodyError = bodyError
        self.contentType = contentType
    }
    var paths: [String] { lock.withLock { recordedPaths } }
    func forward(_ request: PeerHTTPRequest, headTimeout: TimeInterval?) async throws -> PeerHTTPResponse {
        lock.withLock { recordedPaths.append(request.path) }
        var header = PeerHeader()
        header.set("Content-Type", contentType)
        return PeerHTTPResponse(status: status, header: header,
                                body: .fixed(chunks, error: bodyError), cancel: {})
    }
}

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

final class PeerTransportTests: XCTestCase {
    func testOversizedRequestsDoNotPoisonChannelAndSmallRequestStillSucceeds() async throws {
        var limits = PeerWireLimits.default
        limits.maxFrameBytes = 512
        limits.maxRequestBodyBytes = 256
        let channel = ControlledRuntimeTestChannel()
        let multiplexer = PeerHTTPMultiplexer(channel: channel, limits: limits)

        do {
            _ = try await multiplexer.forward(PeerHTTPRequest(
                method: "POST", path: "/chat/v1/responses", body: Data(repeating: 0x61, count: 257)))
            XCTFail("Body above the normalized request limit must be rejected before dispatch")
        } catch {
            XCTAssertEqual(error as? PeerWireError, .requestBodyTooLarge(257))
        }

        var largeHeader = PeerHeader()
        largeHeader.set("X-Padding", String(repeating: "h", count: 300))
        do {
            _ = try await multiplexer.forward(PeerHTTPRequest(
                method: "POST", path: "/chat/v1/responses", header: largeHeader,
                body: Data(repeating: 0x62, count: limits.maxRequestBodyBytes)))
            XCTFail("Encoded request plus header/base64 overhead must respect the frame limit")
        } catch {
            guard case .frameTooLarge(let size)? = error as? PeerWireError else {
                return XCTFail("Expected frameTooLarge, got \(error)")
            }
            XCTAssertGreaterThan(size, limits.maxFrameBytes)
        }
        XCTAssertTrue(channel.sentFrames.isEmpty)
        XCTAssertEqual(multiplexer.openStreamCount, 0)
        XCTAssertFalse(multiplexer.isClosed)

        let small = Task {
            try await multiplexer.forward(PeerHTTPRequest(
                method: "POST", path: "/chat/v1/responses", body: Data("ok".utf8)))
        }
        await channel.waitForSentFrames(1)
        let id = try XCTUnwrap(channel.sentFrames.first?.id)
        try channel.deliver(PeerFrame(type: .responseStart, id: id, status: 200), limits: limits)
        try channel.deliver(PeerFrame(type: .responseEnd, id: id), limits: limits)
        let response = try await small.value
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(try await response.collect(limit: 16), Data())
        XCTAssertEqual(channel.sentFrames.filter { $0.type == .request }.count, 1)
        XCTAssertEqual(multiplexer.openStreamCount, 0)
        await XCTAssertPeerSendersDrained(multiplexer)
        XCTAssertFalse(multiplexer.isClosed)
        multiplexer.close()
    }

    func testChannelDropBeforeHeadersFailsPendingRequestAndDrainsStream() async throws {
        let channel = ControlledRuntimeTestChannel()
        let multiplexer = PeerHTTPMultiplexer(channel: channel)
        let task = Task {
            try await multiplexer.forward(PeerHTTPRequest(method: "GET", path: "/chat/v1/sessions"))
        }
        await channel.waitForSentFrames(1)

        channel.remoteClose()
        do {
            _ = try await task.value
            XCTFail("A dropped channel must not invent response headers")
        } catch {
            XCTAssertEqual(error as? PeerWireError, .channelClosed)
        }
        XCTAssertEqual(multiplexer.openStreamCount, 0)
        await XCTAssertPeerSendersDrained(multiplexer)
        XCTAssertTrue(multiplexer.isClosed)
    }

    func testChannelDropMidFiniteBodyAndMidSSEFailsWithoutSuccessfulEnd() async throws {
        let cases = [
            ("application/json", Data("{\"partial\":".utf8)),
            ("text/event-stream", Data("event: response.output_text.delta\ndata: {\"delta\":\"part\"}\n\n".utf8)),
        ]
        for (contentType, partial) in cases {
            let channel = ControlledRuntimeTestChannel()
            let multiplexer = PeerHTTPMultiplexer(channel: channel)
            let task = Task {
                try await multiplexer.forward(PeerHTTPRequest(method: "GET", path: "/chat/v1/stream"))
            }
            await channel.waitForSentFrames(1)
            let id = try XCTUnwrap(channel.sentFrames.first?.id)
            var header = PeerHeader()
            header.set("Content-Type", contentType)
            try channel.deliver(PeerFrame(type: .responseStart, id: id, header: header, status: 200))
            let response = try await task.value
            try channel.deliver(PeerFrame(type: .responseBody, id: id, body: partial))
            var iterator = response.body.makeAsyncIterator()
            XCTAssertEqual(try await iterator.next(), partial)

            channel.remoteClose()
            do {
                _ = try await iterator.next()
                XCTFail("A truncated \(contentType) response must fail, not report a successful end")
            } catch {
                XCTAssertEqual(error as? PeerWireError, .channelClosed)
            }
            XCTAssertEqual(multiplexer.openStreamCount, 0)
            await XCTAssertPeerSendersDrained(multiplexer)
            XCTAssertTrue(multiplexer.isClosed)
        }
    }

    func testCancellationAfterRequestSendEmitsOneCancelAndIgnoresLateResponse() async throws {
        let channel = ControlledRuntimeTestChannel()
        let multiplexer = PeerHTTPMultiplexer(channel: channel)
        let task = Task {
            try await multiplexer.forward(PeerHTTPRequest(
                method: "POST", path: "/chat/v1/responses", body: Data("mutation".utf8)))
        }
        await channel.waitForSentFrames(1)
        let id = try XCTUnwrap(channel.sentFrames.first?.id)

        task.cancel()
        await XCTAssertThrowsErrorAsync(try await task.value)
        await channel.waitForSentFrames(2)
        XCTAssertEqual(channel.sentFrames.map(\.type), [.request, .cancel])
        XCTAssertEqual(channel.sentFrames.map(\.id), [id, id])
        XCTAssertEqual(multiplexer.openStreamCount, 0)
        await XCTAssertPeerSendersDrained(multiplexer)

        try channel.deliver(PeerFrame(type: .responseStart, id: id, status: 200))
        try channel.deliver(PeerFrame(type: .responseEnd, id: id))
        XCTAssertEqual(channel.sentFrames.map(\.type), [.request, .cancel],
                       "late response frames must not resurrect or re-cancel a retired request")
        XCTAssertEqual(multiplexer.openStreamCount, 0)
        multiplexer.close()
    }

    func testCancellingBackpressuredSenderReleasesTaskWithoutSending() async throws {
        let channel = BackpressuredRuntimeTestChannel()
        let multiplexer = PeerHTTPMultiplexer(channel: channel)
        let task = Task {
            try await multiplexer.forward(PeerHTTPRequest(method: "POST", path: "/chat/v1/responses",
                                                            header: PeerHeader(), body: Data("body".utf8)),
                                          headTimeout: nil)
        }
        for _ in 0..<100 where multiplexer.parkedSenderCount == 0 {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(multiplexer.parkedSenderCount, 1)
        XCTAssertEqual(multiplexer.activeSenderCount, 1)

        task.cancel()
        await XCTAssertThrowsErrorAsync(try await task.value)
        for _ in 0..<100 where multiplexer.activeSenderCount != 0 {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(multiplexer.parkedSenderCount, 0)
        XCTAssertEqual(multiplexer.activeSenderCount, 0)
        XCTAssertEqual(channel.sendCount, 0, "cancelled parked owner must never send its request")
        XCTAssertEqual(multiplexer.openStreamCount, 0)
        multiplexer.close()
    }

    func testCancelledPendingPeerRequestReleasesContinuationAndStream() async throws {
        let multiplexer = PeerHTTPMultiplexer(channel: RuntimeTestChannel())
        let task = Task {
            try await multiplexer.forward(PeerHTTPRequest(method: "GET", path: "/chat/v1/sessions",
                                                            header: PeerHeader(), body: Data()), headTimeout: nil)
        }
        for _ in 0..<100 where multiplexer.openStreamCount == 0 { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(multiplexer.openStreamCount, 1)
        task.cancel()
        await XCTAssertThrowsErrorAsync(try await task.value)
        XCTAssertEqual(multiplexer.openStreamCount, 0)
        multiplexer.close()
    }

    func testBridgeCancellationReleasesLateListenerAndNeverActivates() async throws {
        let listener = ControlledLoopbackListener()
        let authorization = PeerAuthorizationState(PeerAuthorization(peerID: "host", sessionID: "session",
                                                                      expiresAt: .distantFuture))
        let bridge = PeerLoopbackBridge(forwarder: LinkedDevicesForwarder(), authorization: authorization,
                                        listener: listener)
        let task = Task { try await bridge.startPaused() }
        for _ in 0..<100 where !listener.started { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(listener.started)
        task.cancel()
        listener.resume(port: 43220)
        await XCTAssertThrowsErrorAsync(try await task.value)
        XCTAssertTrue(listener.stopped)
        XCTAssertNil(bridge.currentEndpoint)
    }

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

    func testEmptyICEConfigurationIsValidForHostCandidates() throws {
        let value = LinkedDevicesICECredentials(ice_servers: [], expires_at: nil)
        XCTAssertEqual(try LinkedDevicesBrokerClient.validateICE(value), value)
        XCTAssertThrowsError(try LinkedDevicesBrokerClient.validateICE(.init(
            ice_servers: [PeerICEServer(urls: [], username: nil, credential: nil)], expires_at: nil)))
    }

    func testNativePeerPreservesSignedBasePathAndQueryExactly() throws {
        let base = try XCTUnwrap(URL(string: "http://localhost:43215/chat/"))
        let url = try XCTUnwrap(URL(string: "http://localhost:43215/chat/v1/sessions?limit=20"))
        XCTAssertTrue(WebRTCHubTransport.sameOrigin(url, base))
        let peer = try WebRTCHubTransport.peerRequest(from: URLRequest(url: url), url: url)
        XCTAssertEqual(peer.path, "/chat/v1/sessions?limit=20")
        let gate = PeerLoopbackGate(port: 43215, capability: "secret", scopePrefix: "/chat")
        var header = PeerHeader(); header.set("Host", "localhost:43215"); header.set("Cookie", "termllm_peer_43215=secret")
        XCTAssertEqual(gate.evaluate(.init(method: "GET", target: peer.path, version: "HTTP/1.1", header: header, body: Data())), .allow)
        if case .allow = gate.evaluate(.init(method: "GET", target: "/v1/sessions", version: "HTTP/1.1", header: header, body: Data())) {
            XCTFail("request escaped the signed base path")
        }
    }

    func testLoopbackStreamsChunksWithoutStrippingSignedBasePath() async throws {
        let port: UInt16 = 43215
        let capability = "secret"
        let target = "/chat/v1/responses?stream=1%2B2"
        let request = Data([
            "GET \(target) HTTP/1.1\r\n",
            "Host: localhost:\(port)\r\n",
            "Cookie: termllm_peer_\(port)=\(capability)\r\n",
            "Connection: close\r\n",
            "\r\n",
        ].joined().utf8)
        XCTAssertEqual(Data(request.suffix(4)), Data([0x0D, 0x0A, 0x0D, 0x0A]))
        let stream = MemoryPeerByteStream(input: request)
        let forwarder = LinkedDevicesForwarder(chunks: [Data("one".utf8), Data("two".utf8)])
        let configuration = PeerLoopbackConnection.Configuration(
            gate: PeerLoopbackGate(port: port, capability: capability, scopePrefix: "/chat"))
        let connection = PeerLoopbackConnection(stream: stream, forwarder: forwarder,
                                                configuration: configuration, isAuthorized: { true })

        await connection.serve()

        XCTAssertEqual(forwarder.paths, [target], "the signed mount and encoded query must cross unchanged")
        let response = try XCTUnwrap(String(data: stream.written, encoding: .utf8))
        XCTAssertTrue(response.contains("Transfer-Encoding: chunked\r\n"))
        let expectedSuffix = Data("3\r\none\r\n3\r\ntwo\r\n0\r\n\r\n".utf8)
        XCTAssertEqual(Data(stream.written.suffix(expectedSuffix.count)), expectedSuffix,
                       "the loopback bridge must preserve streaming chunk boundaries and termination")
        XCTAssertTrue(stream.closed)
    }

    func testLoopbackAbortsFiniteAndSSEWithoutSuccessTerminatorAfterBodyFailure() async throws {
        let cases = [
            ("application/json", Data("{\"partial\":".utf8)),
            ("text/event-stream", Data("event: response.output_text.delta\ndata: {\"delta\":\"part\"}\n\n".utf8)),
        ]
        for (contentType, partial) in cases {
            let port: UInt16 = 43226
            let capability = "secret"
            let request = Data([
                "GET /chat/v1/stream HTTP/1.1\r\n",
                "Host: localhost:\(port)\r\n",
                "Cookie: termllm_peer_\(port)=\(capability)\r\n",
                "Connection: close\r\n",
                "\r\n",
            ].joined().utf8)
            let stream = MemoryPeerByteStream(input: request)
            let forwarder = LinkedDevicesForwarder(
                chunks: [partial], bodyError: PeerWireError.channelClosed, contentType: contentType)
            let connection = PeerLoopbackConnection(
                stream: stream, forwarder: forwarder,
                configuration: .init(gate: PeerLoopbackGate(
                    port: port, capability: capability, scopePrefix: "/chat")),
                isAuthorized: { true })

            await connection.serve()

            var chunk = Data("\(String(partial.count, radix: 16))\r\n".utf8)
            chunk.append(partial)
            chunk.append(Data("\r\n".utf8))
            XCTAssertEqual(Data(stream.written.suffix(chunk.count)), chunk)
            XCTAssertNil(stream.written.range(of: Data("0\r\n\r\n".utf8)),
                         "A failed \(contentType) stream must remain observably truncated")
            XCTAssertTrue(stream.closed)
        }
    }

    func testPeerBrowserRevokesOnlyTaggedRemoteAuthorizationLoss() throws {
        let url = try XCTUnwrap(URL(string: "http://localhost:43212/chat/"))
        func response(_ status: Int, _ fields: [String: String] = [:]) throws -> HTTPURLResponse {
            try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: fields))
        }
        XCTAssertFalse(BrowserView.shouldRevokeAuthorization(for: try response(403), isLinkedDevices: true))
        XCTAssertFalse(BrowserView.shouldRevokeAuthorization(for: try response(401), isLinkedDevices: true))
        XCTAssertTrue(BrowserView.shouldRevokeAuthorization(for: try response(401, [
            PeerAuthorizationLoss.headerName: PeerAuthorizationLoss.headerValue,
        ]), isLinkedDevices: true))
        XCTAssertTrue(BrowserView.shouldRevokeAuthorization(for: try response(403), isLinkedDevices: false))
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
        let forwarder = LinkedDevicesForwarder(status: 403)
        let authorization = PeerAuthorizationState(PeerAuthorization(peerID: "host", sessionID: "session", expiresAt: .distantFuture))
        let transport = WebRTCHubTransport(forwarder: forwarder, authorization: authorization,
                                            hubBaseURL: URL(string: "http://localhost:43215/")!)
        let request = URLRequest(url: URL(string: "http://localhost:43215/v1/linked-devices")!)
        let callback = LockedFlag()
        await XCTAssertThrowsErrorAsync(try await transport.execute(request, onUnauthorized: { callback.set() }))
        XCTAssertFalse(callback.value)
        XCTAssertTrue(authorization.check())
    }

    func testPendingRequestDropThenReplacementReadSucceedsWithoutReplay() async throws {
        let source = LinkedDevicesSourceTransport()
        let base = try XCTUnwrap(URL(string: "http://localhost:43227/"))
        let request = URLRequest(url: try XCTUnwrap(URL(string: "http://localhost:43227/v1/sessions")))

        let oldChannel = ControlledRuntimeTestChannel()
        let oldMultiplexer = PeerHTTPMultiplexer(channel: oldChannel)
        let oldAuthorization = PeerAuthorizationState(PeerAuthorization(
            peerID: "host", sessionID: "old", expiresAt: .distantFuture))
        source.install(WebRTCHubTransport(forwarder: oldMultiplexer, authorization: oldAuthorization,
                                          hubBaseURL: base))
        let dropped = Task { try await source.execute(request, onUnauthorized: nil) }
        await oldChannel.waitForSentFrames(1)
        oldChannel.remoteClose()
        await XCTAssertThrowsErrorAsync(try await dropped.value)
        XCTAssertEqual(oldChannel.sentFrames.filter { $0.type == .request }.count, 1)
        XCTAssertEqual(oldMultiplexer.openStreamCount, 0)

        let newChannel = ControlledRuntimeTestChannel()
        let newMultiplexer = PeerHTTPMultiplexer(channel: newChannel)
        let newAuthorization = PeerAuthorizationState(PeerAuthorization(
            peerID: "host", sessionID: "new", expiresAt: .distantFuture))
        source.install(WebRTCHubTransport(forwarder: newMultiplexer, authorization: newAuthorization,
                                          hubBaseURL: base))
        let recovered = Task { try await source.execute(request, onUnauthorized: nil) }
        await newChannel.waitForSentFrames(1)
        let id = try XCTUnwrap(newChannel.sentFrames.first?.id)
        var header = PeerHeader()
        header.set("Content-Type", "application/json")
        try newChannel.deliver(PeerFrame(type: .responseStart, id: id, header: header, status: 200))
        try newChannel.deliver(PeerFrame(type: .responseBody, id: id, body: Data("{}".utf8)))
        try newChannel.deliver(PeerFrame(type: .responseEnd, id: id))

        let (data, response) = try await recovered.value
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(data, Data("{}".utf8))
        XCTAssertEqual(newChannel.sentFrames.filter { $0.type == .request }.count, 1)
        XCTAssertEqual(oldChannel.sentFrames.filter { $0.type == .request }.count, 1,
                       "recovery must not replay the dropped request")
        newMultiplexer.close()
    }

    func testConcurrentOldGenerationResultsCannotPublishOrReplayAfterRecovery() async throws {
        let source = LinkedDevicesSourceTransport()
        let base = try XCTUnwrap(URL(string: "http://localhost:43217/"))
        let oldForwarder = ConcurrentDelayedLinkedDevicesForwarder()
        let oldAuthorization = PeerAuthorizationState(PeerAuthorization(
            peerID: "host", sessionID: "old", expiresAt: .distantFuture))
        source.install(WebRTCHubTransport(forwarder: oldForwarder, authorization: oldAuthorization,
                                          hubBaseURL: base))

        let readURL = try XCTUnwrap(URL(string: "http://localhost:43217/v1/sessions"))
        let mutationURL = try XCTUnwrap(URL(string: "http://localhost:43217/v1/responses"))
        var mutation = URLRequest(url: mutationURL)
        mutation.httpMethod = "POST"
        mutation.httpBody = Data("{}".utf8)
        let oldRead = Task { try await source.execute(URLRequest(url: readURL), onUnauthorized: nil) }
        let oldMutation = Task { [mutation] in try await source.execute(mutation, onUnauthorized: nil) }
        await oldForwarder.waitForDispatches(2)

        let replacement = LinkedDevicesForwarder()
        let replacementAuthorization = PeerAuthorizationState(PeerAuthorization(
            peerID: "host", sessionID: "new", expiresAt: .distantFuture))
        source.install(WebRTCHubTransport(forwarder: replacement, authorization: replacementAuthorization,
                                          hubBaseURL: base))
        oldForwarder.finishAll()

        do {
            _ = try await oldRead.value
            XCTFail("An old-generation read must not publish after replacement")
        } catch {
            XCTAssertTrue(error is LinkedDevicesUnavailable)
        }
        do {
            _ = try await oldMutation.value
            XCTFail("An uncertain mutation must not publish or replay after replacement")
        } catch {
            XCTAssertTrue(error is LinkedDevicesUnavailable)
        }
        XCTAssertEqual(oldForwarder.dispatchCount, 2)
        XCTAssertEqual(oldForwarder.methods.sorted(), ["GET", "POST"])
        XCTAssertTrue(replacement.paths.isEmpty, "replacement transport must not replay old work")

        let (data, response) = try await source.execute(URLRequest(url: readURL), onUnauthorized: nil)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(data, Data("{\"ok\":true}".utf8))
        XCTAssertEqual(replacement.paths, ["/v1/sessions"], "a new read should dispatch once on the live generation")
        XCTAssertEqual(oldForwarder.dispatchCount, 2)
    }

    func testStaleUnauthorizedGETCannotRevokeReplacementGeneration() async throws {
        let source = LinkedDevicesSourceTransport()
        let url = try XCTUnwrap(URL(string: "http://localhost:43217/v1/sessions"))
        let forwarder = DelayedLinkedDevicesForwarder(status: 401)
        let oldAuthorization = PeerAuthorizationState(PeerAuthorization(peerID: "host", sessionID: "old",
                                                                         expiresAt: .distantFuture))
        source.install(WebRTCHubTransport(forwarder: forwarder, authorization: oldAuthorization,
                                          hubBaseURL: URL(string: "http://localhost:43217/")!))
        let callback = LockedFlag()
        let task = Task {
            try await source.execute(URLRequest(url: url), onUnauthorized: { callback.set() })
        }
        for _ in 0..<100 where !forwarder.started { try await Task.sleep(nanoseconds: 2_000_000) }
        let replacementAuthorization = PeerAuthorizationState(PeerAuthorization(
            peerID: "host", sessionID: "new", expiresAt: .distantFuture))
        source.install(WebRTCHubTransport(forwarder: LinkedDevicesForwarder(),
                                          authorization: replacementAuthorization,
                                          hubBaseURL: URL(string: "http://localhost:43217/")!))
        forwarder.finish()

        await XCTAssertThrowsErrorAsync(try await task.value)
        XCTAssertFalse(callback.value, "an old generation must not purge the replacement workspace")
        XCTAssertTrue(replacementAuthorization.check())
    }

    @MainActor
    func testStaleUnauthorizedGETCannotPurgeProductionDirectWorkspace() async throws {
        let id = UUID()
        let hostKey = LinkedDevicesBase64URL.encode(Data(repeating: 0x44, count: 32))
        let baseURL = try XCTUnwrap(URL(string: "http://localhost:43224/chat/"))
        let connection = HubConnection(id: id, name: "Desk", kind: .directNode, url: baseURL,
                                       needsKindReview: nil, linkedDevicesHostKey: hostKey)
        let sourceTransport = LinkedDevicesSourceTransport()
        let forwarder = ProductionStaleAuthorizationForwarder()
        let oldAuthorization = PeerAuthorizationState(PeerAuthorization(
            peerID: hostKey, sessionID: "old", expiresAt: .distantFuture, scopePrefix: "/chat"))
        sourceTransport.install(WebRTCHubTransport(forwarder: forwarder, authorization: oldAuthorization,
                                                    hubBaseURL: baseURL))
        let workspace = HubSourceWorkspace(connection: connection, bearerStorage: HubMemoryBearerStorage(),
                                           dataStore: .nonPersistent(), transport: sourceTransport)
        defer { workspace.dispose(removeCredentials: true) }
        let browserIdentity = workspace.browserIdentity
        let workspaceEpoch = workspace.authEpoch
        let storeEpoch = workspace.store.authEpoch
        let refresh = Task { @MainActor in await workspace.store.refresh() }
        for _ in 0..<100 where !forwarder.started { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(forwarder.started)

        let replacementAuthorization = PeerAuthorizationState(PeerAuthorization(
            peerID: hostKey, sessionID: "new", expiresAt: .distantFuture, scopePrefix: "/chat"))
        sourceTransport.install(WebRTCHubTransport(forwarder: LinkedDevicesForwarder(),
                                                    authorization: replacementAuthorization,
                                                    hubBaseURL: baseURL))
        forwarder.finishUnauthorized()
        await refresh.value
        for _ in 0..<10 { await Task.yield() }

        XCTAssertFalse(workspace.store.unauthorized)
        XCTAssertFalse(workspace.browserRevoked)
        XCTAssertEqual(workspace.authEpoch, workspaceEpoch)
        XCTAssertEqual(workspace.store.authEpoch, storeEpoch)
        XCTAssertEqual(workspace.browserIdentity, browserIdentity)
        XCTAssertTrue(replacementAuthorization.check())
    }

    func testSourceTransportNeverRetriesAcrossConnections() async throws {
        let source = LinkedDevicesSourceTransport()
        let url = try XCTUnwrap(URL(string: "http://localhost:43213/v1/sessions"))
        let request = URLRequest(url: url)
        await XCTAssertThrowsErrorAsync(try await source.execute(request, onUnauthorized: nil))

        let forwarder = LinkedDevicesForwarder()
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

private func XCTAssertPeerSendersDrained(_ multiplexer: PeerHTTPMultiplexer,
                                         file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<1_000 where multiplexer.activeSenderCount != 0 { await Task.yield() }
    XCTAssertEqual(multiplexer.activeSenderCount, 0, "request sender slot did not drain", file: file, line: line)
    XCTAssertEqual(multiplexer.parkedSenderCount, 0, "parked sender slot did not drain", file: file, line: line)
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                          file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
