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
        do {
            let result = try await transport.execute(request, onUnauthorized: onUnauthorized)
            guard lock.withLock({ generation == expectedGeneration }) else {
                throw MobileSharingUnavailable(message: "The shared host reconnected while the request was running. It was not retried.")
            }
            return result
        } catch {
            // Never pick up a newer transport and replay this request.
            throw error
        }
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
        init(connection: HubConnection) { self.connection = connection }
    }

    private var entries: [UUID: Entry] = [:]
    private let identities: MobileSharingIdentityStore
    private var connector: (any MobileSharingSessionConnecting)?
    private let pathMonitor: NWPathMonitor
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
         pathMonitor: NWPathMonitor = NWPathMonitor()) {
        self.identities = identities
        self.connector = connector
        self.pathMonitor = pathMonitor
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

    /// Mirrors the saved catalog. Removed sources lose their runtime,
    /// credentials and isolated browser data. Offline/revoked sources remain.
    func synchronize(_ connections: [HubConnection]) {
        let peers = Dictionary(uniqueKeysWithValues: connections.filter(\.isMobileSharing).map { ($0.id, $0) })
        for (id, entry) in entries where peers[id] == nil {
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
        return try await enroll(paired, fallbackName: link.hostLabel ?? "Shared host", in: catalog, token: token)
    }

    /// Makes a verified pairing visible as a saved source only after its real
    /// DataChannel and stable-origin browser bridge are both live.
    func enroll(_ paired: MobileSharingConnector.Paired, fallbackName: String,
                in catalog: HubConnectionStore, token: UUID) async throws -> HubConnection {
        let encodedKey = MobileSharingBase64URL.encode(paired.credential.hostKey)
        let existing = catalog.connections.first { $0.mobileSharingHostKey == encodedKey }
        if let existingEntry = existing.flatMap({ entries[$0.id] }) { tearDownConnection(existingEntry) }
        let preferred = existing?.url.port.flatMap { UInt16(exactly: $0) }
        let bridge = PeerLoopbackBridge(forwarder: paired.live.forwarder,
                                        authorization: paired.live.authorization,
                                        listener: PeerNWLoopbackListener(), cookiePolicy: .isolate,
                                        preferredPort: preferred)
        do {
            let endpoint = try await bridge.start()
            if let preferred, endpoint.port != preferred { throw MobileSharingUnavailable(message: "The saved browser origin could not be restored.") }
            let name = paired.credential.hostLabel?.isEmpty == false ? paired.credential.hostLabel! : fallbackName
            let connection = try catalog.saveMobileSharing(name: name, hostKey: paired.credential.hostKey,
                                                             bridgePort: endpoint.port,
                                                             basePath: paired.credential.basePath ?? "/")
            let dataStore = WKWebsiteDataStore(forIdentifier: connection.id)
            await bridge.installCapability(in: dataStore.httpCookieStore)
            let entry = entry(for: connection)
            entry.connection = connection
            entry.live = paired.live
            entry.bridge = bridge
            entry.activeToken = token
            entry.task = nil
            entry.attempt = 0
            entry.terminal = false
            entry.transport.install(WebRTCHubTransport(forwarder: paired.live.forwarder,
                                                        authorization: paired.live.authorization,
                                                        hubBaseURL: connection.url))
            statuses[connection.id] = .connected(relayed: nil)
            updateSelectedPair(for: entry, live: paired.live)
            return connection
        } catch {
            bridge.revoke()
            paired.live.close()
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
        guard foreground, networkAvailable, !entry.terminal, entry.live == nil,
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
                try await self.attach(live, to: entry)
            } catch {
                guard !Task.isCancelled, self.entries[sourceID] === entry, !entry.terminal,
                      entry.activeToken == token else { return }
                entry.task = nil
                if let protocolError = error as? MobileSharingProtocolError,
                   protocolError == .hostIdentityChanged {
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

    private func attach(_ live: MobileSharingLiveConnection, to entry: Entry) async throws {
        guard let port = entry.connection.url.port, let preferredPort = UInt16(exactly: port) else {
            live.close()
            throw MobileSharingUnavailable(message: "The saved browser origin is invalid. Remove the source and pair again.")
        }
        let bridge = PeerLoopbackBridge(forwarder: live.forwarder, authorization: live.authorization,
                                        listener: PeerNWLoopbackListener(), cookiePolicy: .isolate,
                                        preferredPort: preferredPort)
        let endpoint = try await bridge.start()
        guard endpoint.port == preferredPort else {
            bridge.revoke(); live.close()
            throw MobileSharingUnavailable(message: "The saved browser origin could not be restored.")
        }
        let dataStore = WKWebsiteDataStore(forIdentifier: entry.connection.id)
        await bridge.installCapability(in: dataStore.httpCookieStore)
        entry.live = live
        entry.bridge = bridge
        entry.task = nil
        entry.attempt = 0
        entry.transport.install(WebRTCHubTransport(forwarder: live.forwarder, authorization: live.authorization,
                                                     hubBaseURL: entry.connection.url))
        statuses[entry.connection.id] = .connected(relayed: nil)
        updateSelectedPair(for: entry, live: live)
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
             MobileSharingBrokerError.invalidAddress:
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
        case let value as MobileSharingBrokerError where shouldStopAutomatically(value):
            return value.localizedDescription
        default: return "Shared host is unavailable. It will reconnect without replaying requests."
        }
    }
}
