import Combine
import Foundation
import Network
import WebKit

struct MobileSharingUnavailable: Error, LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// One authenticated WebRTC connection after the signed v2 transport
/// handshake has completed. Pairing/reconnect code is the only producer.
struct MobileSharingLiveConnection: @unchecked Sendable {
    let forwarder: PeerHTTPMultiplexer
    let authorization: PeerAuthorizationState
    let stats: @Sendable () async -> PeerSessionStats
    let close: @Sendable () -> Void
}

protocol MobileSharingSessionConnecting: Sendable {
    func reconnect(credential: MobileSharingCredential,
                   closed: @escaping @Sendable () -> Void) async throws -> MobileSharingLiveConnection
}

/// A stable HubTransport injected into DirectNodeClient. The underlying peer
/// connection may be replaced after suspend/network loss, while callers keep
/// source identity. Requests are attempted exactly once: this layer never
/// replays an uncertain mutation on a replacement connection.
final class MobileSharingSourceTransport: HubTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var current: WebRTCHubTransport?
    private var generation: UInt64 = 0

    func install(_ transport: WebRTCHubTransport) {
        lock.withLock {
            generation &+= 1
            current = transport
        }
    }

    func disconnect() {
        lock.withLock {
            generation &+= 1
            current = nil
        }
    }

    func execute(_ request: URLRequest,
                 onUnauthorized: (@Sendable () async -> Void)?) async throws -> (Data, HTTPURLResponse) {
        let snapshot: (WebRTCHubTransport, UInt64)? = lock.withLock {
            current.map { ($0, generation) }
        }
        guard let (transport, expectedGeneration) = snapshot else {
            throw MobileSharingUnavailable(message: "This shared host is offline. The request was not retried.")
        }
        let guardedUnauthorized: (@Sendable () async -> Void)? = onUnauthorized.map { callback in
            { [weak self] in
                guard let self, self.lock.withLock({ self.current === transport && self.generation == expectedGeneration }) else {
                    return
                }
                await callback()
            }
        }
        do {
            let result = try await transport.execute(request, onUnauthorized: guardedUnauthorized)
            guard lock.withLock({ generation == expectedGeneration }) else {
                if ["GET", "HEAD"].contains(request.httpMethod?.uppercased() ?? "GET") { return result }
                throw MobileSharingUnavailable(message: "The shared host reconnected while the request was running. It was not retried.")
            }
            return result
        } catch {
            // Never pick up a newer transport and replay this request.
            throw error
        }
    }
}

private final class MobileSharingOfflineForwarder: PeerHTTPForwarding, @unchecked Sendable {
    func forward(_ request: PeerHTTPRequest, headTimeout: TimeInterval?) async throws -> PeerHTTPResponse {
        var header = PeerHeader()
        header.set("Content-Type", "text/plain; charset=utf-8")
        return PeerHTTPResponse(status: 503, header: header,
                                body: .fixed([Data("Shared host is offline.\n".utf8)]), cancel: {})
    }
}

@MainActor
final class MobileSharingRuntime: ObservableObject {
    static let shared = MobileSharingRuntime()

    enum Status: Equatable, Sendable {
        case offline
        case connecting
        case connected(relayed: Bool?)
        case suspended
        case revoked
        case identityChanged
        case failed(String)

        var label: String {
            switch self {
            case .offline: "Offline"
            case .connecting: "Connecting…"
            case .connected(let relayed): relayed == true ? "Connected · relay" : relayed == false ? "Connected · direct" : "Connected"
            case .suspended: "Paused while the app is in the background"
            case .revoked: "Access revoked or target reset"
            case .identityChanged: "Host identity changed"
            case .failed(let message): message
            }
        }
    }

    @Published private(set) var statuses: [UUID: Status] = [:]
    private final class Entry {
        var connection: HubConnection
        let transport = MobileSharingSourceTransport()
        var task: Task<Void, Never>?
        var live: MobileSharingLiveConnection?
        var bridge: PeerLoopbackBridge?
        var activeToken: UUID?
        var attempt = 0
        var terminal = false
        var enrolling = false
        init(connection: HubConnection) { self.connection = connection }
    }

    private var entries: [UUID: Entry] = [:]
    private let identities: MobileSharingIdentityStore
    private var connector: (any MobileSharingSessionConnecting)?
    private let pathMonitor: NWPathMonitor
    private let makeListener: () -> any PeerLoopbackListening
    private let monitorQueue = DispatchQueue(label: "com.termllm.mobile-sharing.path")
    private var networkAvailable = true
    private var foreground = true

    #if canImport(Security)
    convenience init() {
        let identities = MobileSharingIdentityStore()
        self.init(identities: identities, connector: MobileSharingConnector(identities: identities))
    }
    #endif

    init(identities: MobileSharingIdentityStore,
         connector: (any MobileSharingSessionConnecting)?,
         pathMonitor: NWPathMonitor = NWPathMonitor(),
         makeListener: @escaping () -> any PeerLoopbackListening = { PeerNWLoopbackListener() }) {
        self.identities = identities
        self.connector = connector
        self.pathMonitor = pathMonitor
        self.makeListener = makeListener
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in self?.networkChanged(path.status == .satisfied) }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    deinit { pathMonitor.cancel() }

    func setConnector(_ connector: any MobileSharingSessionConnecting) {
        self.connector = connector
        reconnectEligibleSources(immediate: true)
    }

    func transport(for connection: HubConnection) -> (any HubTransport)? {
        guard connection.isMobileSharing else { return nil }
        return entry(for: connection).transport
    }

    func status(for sourceID: UUID) -> Status { statuses[sourceID] ?? .offline }

    /// Reinstalls only the capability owned by the still-current bridge. Used
    /// after a source authorization purge during approved re-pair restoration.
    func reinstallCapability(for sourceID: UUID) async -> Bool {
        guard let entry = entries[sourceID], !entry.terminal,
              let endpoint = entry.bridge?.currentEndpoint,
              let token = entry.activeToken else { return false }
        let dataStore = WKWebsiteDataStore(forIdentifier: sourceID)
        await endpoint.installCapability(in: dataStore.httpCookieStore)
        return entries[sourceID] === entry && entry.activeToken == token && !entry.terminal &&
            entry.bridge?.currentEndpoint == endpoint
    }

    /// Mirrors the saved catalog. Removed sources lose their runtime,
    /// credentials and isolated browser data. Offline/revoked sources remain.
    func synchronize(_ connections: [HubConnection]) {
        let peers = Dictionary(uniqueKeysWithValues: connections.filter(\.isMobileSharing).map { ($0.id, $0) })
        for (id, entry) in entries where peers[id] == nil && !entry.enrolling {
            entries[id] = nil
            statuses[id] = nil
            tearDown(entry)
            if let key = hostKey(entry.connection) { try? identities.remove(hostKey: key) }
            let store = WKWebsiteDataStore(forIdentifier: id)
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        }
        for connection in peers.values {
            let entry = entry(for: connection)
            if entry.connection.mobileSharingHostKey != connection.mobileSharingHostKey {
                markTerminal(entry, .identityChanged)
                continue
            }
            entry.connection = connection
            startIfEligible(entry, immediate: true)
        }
    }

    func setForeground(_ value: Bool) {
        guard foreground != value else { return }
        foreground = value
        if value { reconnectEligibleSources(immediate: true) }
        else {
            for entry in entries.values {
                entry.task?.cancel()
                entry.task = nil
                statuses[entry.connection.id] = entry.live == nil ? .suspended : statuses[entry.connection.id]
            }
        }
    }

    func reconnectNow(_ sourceID: UUID) {
        guard let entry = entries[sourceID], !entry.terminal else { return }
        tearDownConnection(entry)
        startIfEligible(entry, immediate: true)
    }

    func pair(link: MobileSharingPairingLink, deviceName: String,
              catalog: HubConnectionStore,
              sasReady: @escaping @Sendable (String) -> Void) async throws -> HubConnection {
        guard let connector = connector as? MobileSharingConnector else {
            throw MobileSharingUnavailable(message: "The WebRTC transport is not available in this build.")
        }
        let hostKey = link.hostKey
        let token = UUID()
        let paired = try await connector.pair(link: link, deviceName: deviceName, sasReady: sasReady) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let entry = self.entries.values.first(where: { self.hostKey($0.connection) == hostKey }) else { return }
                self.connectionClosed(entry, token: token)
            }
        }
        // Once pair_answer is verified the host grant is durable. Enrollment is
        // an independently owned transaction and must finish even if the sheet
        // task is cancelled immediately afterward.
        let enrollment = Task { @MainActor [self] in
            try await enroll(paired, fallbackName: link.hostLabel ?? "Shared host", in: catalog, token: token)
        }
        return try await enrollment.value
    }

    /// Reserves runtime ownership, loopback origin and capability cookie before
    /// publishing the catalog entry. A verified grant is always represented,
    /// even when its first transport attempt failed or was cancelled.
    func enroll(_ paired: MobileSharingConnector.Paired, fallbackName: String,
                in catalog: HubConnectionStore, token: UUID) async throws -> HubConnection {
        let encodedKey = MobileSharingBase64URL.encode(paired.credential.hostKey)
        let existing = catalog.connections.first { $0.mobileSharingHostKey == encodedKey }
        let sourceID = existing?.id ?? UUID()
        let preferred = existing?.url.port.flatMap { UInt16(exactly: $0) }
        let basePath = paired.credential.basePath ?? "/"
        let normalized = basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = normalized.isEmpty ? "/" : "/" + normalized + "/"
        let name = paired.credential.hostLabel?.isEmpty == false ? paired.credential.hostLabel! : fallbackName

        let provisionalURL = existing?.url ?? URL(string: "http://localhost:\(preferred ?? 1024)\(path)")!
        let provisional = HubConnection(id: sourceID, name: name, kind: .directNode, url: provisionalURL,
                                        needsKindReview: nil, mobileSharingHostKey: encodedKey)
        let reservedEntry = entry(for: provisional)
        tearDownConnection(reservedEntry)
        reservedEntry.connection = provisional
        reservedEntry.enrolling = true
        reservedEntry.terminal = false
        reservedEntry.activeToken = token

        let authorization = paired.live?.authorization ?? PeerAuthorizationState(PeerAuthorization(
            peerID: encodedKey, sessionID: "offline-\(UUID().uuidString)", expiresAt: .distantFuture,
            scopePrefix: basePath))
        let forwarder: any PeerHTTPForwarding
        if let live = paired.live { forwarder = live.forwarder }
        else { forwarder = MobileSharingOfflineForwarder() }
        let bridge = PeerLoopbackBridge(forwarder: forwarder, authorization: authorization,
                                        listener: makeListener(), cookiePolicy: .isolate,
                                        preferredPort: preferred)
        do {
            let endpoint = try await bridge.startPaused()
            if let preferred, endpoint.port != preferred {
                throw MobileSharingUnavailable(message: "The saved browser origin could not be restored.")
            }
            guard let url = HubConnectionStore.canonicalMobileSharingBridgeURL(
                "http://localhost:\(endpoint.port)\(path)") else {
                throw MobileSharingUnavailable(message: "The shared browser origin is invalid.")
            }
            let candidate = HubConnection(id: sourceID, name: name, kind: .directNode, url: url,
                                          needsKindReview: nil, mobileSharingHostKey: encodedKey)
            let entry = reservedEntry
            guard entries[sourceID] === entry, entry.activeToken == token, entry.enrolling else {
                throw CancellationError()
            }
            entry.connection = candidate
            entry.live = paired.live
            entry.bridge = bridge
            entry.task = nil

            let dataStore = WKWebsiteDataStore(forIdentifier: sourceID)
            await endpoint.installCapability(in: dataStore.httpCookieStore)
            guard entries[sourceID] === entry, entry.activeToken == token, entry.enrolling else {
                throw CancellationError()
            }
            try bridge.activate()

            let connection = try catalog.saveMobileSharing(id: sourceID, name: name,
                                                             hostKey: paired.credential.hostKey,
                                                             bridgePort: endpoint.port, basePath: basePath)
            guard entries[sourceID] === entry, entry.activeToken == token, entry.enrolling else {
                throw CancellationError()
            }
            entry.connection = connection
            entry.enrolling = false
            entry.attempt = 0
            if let live = paired.live {
                entry.transport.install(WebRTCHubTransport(forwarder: live.forwarder,
                                                            authorization: live.authorization,
                                                            hubBaseURL: connection.url))
                statuses[sourceID] = .connected(relayed: nil)
                updateSelectedPair(for: entry, live: live)
            } else {
                statuses[sourceID] = .offline
                startIfEligible(entry, immediate: true)
            }
            return connection
        } catch {
            bridge.revoke()
            paired.live?.close()
            let entry = reservedEntry
            guard entries[sourceID] === entry, entry.activeToken == token else { throw CancellationError() }
            entry.enrolling = false
            if existing == nil { entries[sourceID] = nil; statuses[sourceID] = nil }
            if let existing, let port = existing.url.port.flatMap({ UInt16(exactly: $0) }) {
                // Re-pairing an existing workspace must never destroy its only
                // visible recovery path. Keep it offline and let normal bounded
                // reconnect restore the same origin.
                let connection = try catalog.saveMobileSharing(id: existing.id, name: name,
                                                                 hostKey: paired.credential.hostKey,
                                                                 bridgePort: port, basePath: basePath)
                let entry = reservedEntry
                entry.connection = connection
                entry.bridge = nil
                entry.live = nil
                entry.enrolling = false
                entry.terminal = false
                entry.activeToken = token
                statuses[sourceID] = .offline
                startIfEligible(entry, immediate: true)
                return connection
            }
            if existing == nil, !catalog.connections.contains(where: { $0.id == sourceID }) {
                try? identities.remove(hostKey: paired.credential.hostKey)
                throw MobileSharingUnavailable(message: "The approved source could not be saved on this phone. Revoke this device on the host before scanning another QR code.")
            }
            throw error
        }
    }

    func markRevoked(_ sourceID: UUID) {
        guard let entry = entries[sourceID] else { return }
        markTerminal(entry, .revoked)
    }

    func markIdentityChanged(_ sourceID: UUID) {
        guard let entry = entries[sourceID] else { return }
        markTerminal(entry, .identityChanged)
    }

    private func entry(for connection: HubConnection) -> Entry {
        if let entry = entries[connection.id] { return entry }
        let entry = Entry(connection: connection)
        entries[connection.id] = entry
        statuses[connection.id] = .offline
        return entry
    }

    private func networkChanged(_ available: Bool) {
        guard networkAvailable != available else { return }
        networkAvailable = available
        if available { reconnectEligibleSources(immediate: true) }
        else {
            for entry in entries.values where entry.live == nil && !entry.terminal {
                entry.task?.cancel()
                entry.task = nil
                statuses[entry.connection.id] = .offline
            }
        }
    }

    private func reconnectEligibleSources(immediate: Bool) {
        for entry in entries.values { startIfEligible(entry, immediate: immediate) }
    }

    private func startIfEligible(_ entry: Entry, immediate: Bool) {
        guard foreground, networkAvailable, !entry.terminal, !entry.enrolling, entry.live == nil,
              entry.task == nil, connector != nil else { return }
        guard let key = hostKey(entry.connection) else {
            markTerminal(entry, .identityChanged)
            return
        }
        let credential: MobileSharingCredential
        do { credential = try identities.load(hostKey: key) }
        catch {
            statuses[entry.connection.id] = .failed(error.localizedDescription)
            return
        }
        guard credential.hostKey == key else {
            markTerminal(entry, .identityChanged)
            return
        }
        let delay: UInt64 = immediate ? 0 : Self.backoffNanoseconds(attempt: entry.attempt)
        let token = UUID()
        entry.activeToken = token
        statuses[entry.connection.id] = .connecting
        let sourceID = entry.connection.id
        entry.task = Task { @MainActor [weak self, weak entry] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard !Task.isCancelled, let self, let entry, self.entries[sourceID] === entry,
                  let connector = self.connector else { return }
            do {
                let live = try await connector.reconnect(credential: credential) { [weak self, weak entry] in
                    Task { @MainActor in self?.connectionClosed(entry, token: token) }
                }
                guard !Task.isCancelled, self.entries[sourceID] === entry, entry.activeToken == token else { live.close(); return }
                try await self.attach(live, to: entry, sourceID: sourceID, token: token)
            } catch {
                guard !Task.isCancelled, self.entries[sourceID] === entry, !entry.terminal,
                      entry.activeToken == token else { return }
                entry.task = nil
                if let protocolError = error as? MobileSharingProtocolError,
                   protocolError == .hostIdentityChanged || protocolError == .badSignature {
                    self.markTerminal(entry, .identityChanged)
                    return
                }
                if let protocolError = error as? MobileSharingProtocolError,
                   protocolError == .revoked {
                    self.markTerminal(entry, .revoked)
                    return
                }
                if Self.shouldStopAutomatically(error) {
                    self.statuses[sourceID] = .failed(Self.safeMessage(error))
                    return
                }
                entry.attempt += 1
                self.statuses[sourceID] = .failed(Self.safeMessage(error))
                self.startIfEligible(entry, immediate: false)
            }
        }
    }

    private func owns(_ entry: Entry, sourceID: UUID, token: UUID) -> Bool {
        entries[sourceID] === entry && entry.activeToken == token && !entry.terminal && !entry.enrolling
    }

    private func attach(_ live: MobileSharingLiveConnection, to entry: Entry,
                        sourceID: UUID, token: UUID) async throws {
        guard owns(entry, sourceID: sourceID, token: token),
              let port = entry.connection.url.port, let preferredPort = UInt16(exactly: port) else {
            live.close()
            throw CancellationError()
        }
        // Release the offline/old listener before binding the same stable port.
        let previous = entry.bridge
        entry.bridge = nil
        previous?.revoke()
        let bridge = PeerLoopbackBridge(forwarder: live.forwarder, authorization: live.authorization,
                                        listener: makeListener(), cookiePolicy: .isolate,
                                        preferredPort: preferredPort)
        do {
            let endpoint = try await bridge.startPaused()
            guard endpoint.port == preferredPort, owns(entry, sourceID: sourceID, token: token),
                  live.authorization.check(), !Task.isCancelled else {
                throw CancellationError()
            }
            let dataStore = WKWebsiteDataStore(forIdentifier: sourceID)
            await endpoint.installCapability(in: dataStore.httpCookieStore)
            guard owns(entry, sourceID: sourceID, token: token), live.authorization.check(),
                  !Task.isCancelled else { throw CancellationError() }
            try bridge.activate()
            guard owns(entry, sourceID: sourceID, token: token), live.authorization.check() else {
                throw CancellationError()
            }
            entry.live = live
            entry.bridge = bridge
            entry.task = nil
            entry.attempt = 0
            entry.transport.install(WebRTCHubTransport(forwarder: live.forwarder, authorization: live.authorization,
                                                        hubBaseURL: entry.connection.url))
            statuses[sourceID] = .connected(relayed: nil)
            updateSelectedPair(for: entry, live: live)
        } catch {
            bridge.revoke()
            live.close()
            throw error
        }
    }

    private func updateSelectedPair(for entry: Entry, live: MobileSharingLiveConnection) {
        Task { @MainActor [weak self, weak entry] in
            let stats = await live.stats()
            guard let self, let entry, self.entries[entry.connection.id] === entry,
                  let current = entry.live, current.authorization === live.authorization else { return }
            let known = stats.localCandidateType != nil || stats.remoteCandidateType != nil
            self.statuses[entry.connection.id] = .connected(relayed: known ? stats.isRelayed : nil)
        }
    }

    private func connectionClosed(_ entry: Entry?, token: UUID) {
        guard let entry, entries[entry.connection.id] === entry, entry.activeToken == token else { return }
        tearDownConnection(entry)
        guard !entry.terminal else { return }
        statuses[entry.connection.id] = foreground ? .offline : .suspended
        startIfEligible(entry, immediate: false)
    }

    private func markTerminal(_ entry: Entry, _ status: Status) {
        entry.terminal = true
        tearDownConnection(entry)
        statuses[entry.connection.id] = status
    }

    private func tearDown(_ entry: Entry) {
        entry.terminal = true
        entry.task?.cancel()
        entry.task = nil
        tearDownConnection(entry)
    }

    private func tearDownConnection(_ entry: Entry) {
        entry.task?.cancel()
        entry.task = nil
        entry.activeToken = nil
        entry.transport.disconnect()
        entry.bridge?.revoke()
        entry.bridge = nil
        entry.live?.close()
        entry.live = nil
    }

    private func hostKey(_ connection: HubConnection) -> Data? {
        guard let encoded = connection.mobileSharingHostKey,
              let key = MobileSharingBase64URL.decode(encoded, maximumBytes: 32), key.count == 32 else { return nil }
        return key
    }

    static func backoffNanoseconds(attempt: Int) -> UInt64 {
        let seconds = min(30.0, pow(2.0, Double(min(attempt, 5))))
        return UInt64(seconds * 1_000_000_000)
    }

    static func shouldStopAutomatically(_ error: Error) -> Bool {
        switch error {
        case MobileSharingBrokerError.superseded, MobileSharingBrokerError.rateLimited,
             MobileSharingBrokerError.quotaExceeded, MobileSharingBrokerError.badRequest,
             MobileSharingBrokerError.tooLarge, MobileSharingBrokerError.malformed,
             MobileSharingBrokerError.invalidAddress, MobileSharingProtocolError.invalid(_):
            return true
        default:
            return false
        }
    }

    static func safeMessage(_ error: Error) -> String {
        switch error {
        case let value as MobileSharingUnavailable: return value.message
        case MobileSharingStorageError.hostMismatch, MobileSharingProtocolError.hostIdentityChanged: return "Host identity changed"
        case MobileSharingStorageError.missing: return "Pairing credentials are missing. Pair again."
        case MobileSharingStorageError.corrupt: return "Pairing credentials are unreadable. Remove the source and pair again."
        case MobileSharingProtocolError.invalid(_): return "The host returned invalid transport data. Reconnect manually or pair again."
        case let value as MobileSharingBrokerError where shouldStopAutomatically(value):
            return value.localizedDescription
        default: return "Shared host is unavailable. It will reconnect without replaying requests."
        }
    }
}
