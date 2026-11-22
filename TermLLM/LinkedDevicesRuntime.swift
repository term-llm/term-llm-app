import Combine
import Foundation
import Network
import WebKit

struct LinkedDevicesUnavailable: Error, LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// One authenticated WebRTC connection after the signed v2 transport
/// handshake has completed. Pairing/reconnect code is the only producer.
struct LinkedDevicesLiveConnection: Sendable {
    let forwarder: PeerHTTPMultiplexer
    let authorization: PeerAuthorizationState
    let diagnostics: LinkedDevicesDiagnosticConnection?
    let stats: @Sendable () async -> PeerSessionStats
    let close: @Sendable () -> Void

    init(forwarder: PeerHTTPMultiplexer, authorization: PeerAuthorizationState,
         diagnostics: LinkedDevicesDiagnosticConnection? = nil,
         stats: @escaping @Sendable () async -> PeerSessionStats,
         close: @escaping @Sendable () -> Void) {
        self.forwarder = forwarder
        self.authorization = authorization
        self.diagnostics = diagnostics
        self.stats = stats
        self.close = close
    }
}

protocol LinkedDevicesSessionConnecting: Sendable {
    func reconnect(credential: LinkedDevicesCredential,
                   closed: @escaping @Sendable () -> Void) async throws -> LinkedDevicesLiveConnection
}

/// A stable HubTransport injected into DirectNodeClient. The underlying peer
/// connection may be replaced after suspend/network loss, while callers keep
/// source identity. Requests are attempted exactly once: this layer never
/// replays an uncertain mutation on a replacement connection.
// Sendability: lock protects current/generation as one snapshot. Network work
// uses the captured Sendable transport outside the lock and checks ownership later.
final class LinkedDevicesSourceTransport: HubTransport, @unchecked Sendable {
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
                 onUnauthorized _: (@Sendable () async -> Void)?) async throws -> (Data, HTTPURLResponse) {
        let snapshot: (WebRTCHubTransport, UInt64)? = lock.withLock {
            current.map { ($0, generation) }
        }
        guard let (transport, expectedGeneration) = snapshot else {
            throw LinkedDevicesUnavailable(message: "This linked host is offline. The request was not retried.")
        }
        let result = try await transport.execute(request, onUnauthorized: nil)
        // No result from a retired connection may publish into the
        // replacement generation, and no request is replayed there.
        guard lock.withLock({ generation == expectedGeneration && current === transport }) else {
            throw LinkedDevicesUnavailable(message: "The linked host reconnected while the request was running. It was not retried.")
        }
        return result
    }
}

// Sendability: the sole mutable field, closed, is always accessed under lock.
private final class LinkedDevicesEnrollmentTransportState: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    var isClosed: Bool { lock.withLock { closed } }
    func markClosed() { lock.withLock { closed = true } }
}

private final class LinkedDevicesOfflineForwarder: PeerHTTPForwarding, Sendable {
    func forward(_ request: PeerHTTPRequest, headTimeout: TimeInterval?) async throws -> PeerHTTPResponse {
        var header = PeerHeader()
        header.set("Content-Type", "text/plain; charset=utf-8")
        return PeerHTTPResponse(status: 503, header: header,
                                body: .fixed([Data("Linked host is offline.\n".utf8)]), cancel: {})
    }
}

/// What a verified linked host advertises at `GET /v1/capabilities` (relative
/// to its advertised mount). Parsing is fail-closed: only the literal JSON
/// boolean `true` at `linked_devices.device_tools` enables device tools; a
/// missing, malformed, oversized, numeric/string or non-object answer is "no".
struct LinkedDevicesHostCapabilities: Equatable, Sendable {
    static let unsupported = LinkedDevicesHostCapabilities(deviceTools: false)
    static let path = "/v1/capabilities"
    static let maximumResponseBytes = 64 * 1024

    var deviceTools: Bool

    static func parse(_ data: Data) -> LinkedDevicesHostCapabilities {
        guard data.count <= maximumResponseBytes,
              let root = try? JSONValue.decode(data),
              case .bool(true)? = root["linked_devices"]?["device_tools"] else { return .unsupported }
        return LinkedDevicesHostCapabilities(deviceTools: true)
    }

    /// The origin-relative request for `mount` (the source's loopback URL). It
    /// carries no cookie or credential; the peer transport filters headers.
    static func request(mount: URL) -> URLRequest? {
        guard var components = URLComponents(url: mount, resolvingAgainstBaseURL: false) else { return nil }
        var prefix = components.percentEncodedPath
        while prefix.hasSuffix("/") { prefix.removeLast() }
        components.percentEncodedPath = prefix + path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// One attempt. A definitive answer (200, or a 4xx such as 404 from an older
    /// host) is returned; transport failures and 5xx throw so they may be retried.
    static func fetch(over transport: any HubTransport, mount: URL) async throws -> LinkedDevicesHostCapabilities {
        guard let urlRequest = Self.request(mount: mount) else { return .unsupported }
        let (data, response) = try await transport.execute(urlRequest, onUnauthorized: nil)
        if response.statusCode >= 500 {
            throw LinkedDevicesUnavailable(message: "The linked host could not report its capabilities.")
        }
        guard response.statusCode == 200 else { return .unsupported }
        return parse(data)
    }

    /// Bounded retry for transport failures only; never replays after an answer.
    /// Returns nil when no answer could be obtained, distinct from a definitive no.
    static func resolve(
        over transport: any HubTransport, mount: URL,
        retryDelays: [Duration] = [.seconds(1), .seconds(3)]
    ) async -> LinkedDevicesHostCapabilities? {
        var delays = retryDelays[...]
        while true {
            do { return try await fetch(over: transport, mount: mount) }
            catch is PeerScopeDenied { return Self.unsupported }  // old hosts may omit the route from scope
            catch PeerWireError.responseBufferOverflow { return Self.unsupported }
            catch PeerWireError.unauthorized(_) { return nil }  // the session is retired, not a capability answer
            catch {
                guard !Task.isCancelled, !(error is CancellationError), let delay = delays.popFirst() else { return nil }
                do { try await Task.sleep(for: delay) } catch { return nil }
            }
        }
    }
}

@MainActor
final class LinkedDevicesRuntime: ObservableObject {
    static let shared = LinkedDevicesRuntime()

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

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    /// A connection is closed this long after the app goes to the background,
    /// unless its page is capturing (a Live call, which must keep working
    /// while the phone is locked). Playing audio keeps the app running in the
    /// background, and an open connection keeps the radio awake: the host
    /// sends ICE keepalives every 2 s. The grace is shorter than the host's
    /// 25 s ICE failure timeout: after a longer suspension the connection is
    /// replaced on return instead of trusted.
    static let backgroundGrace: Duration = .seconds(20)

    @Published private(set) var statuses: [UUID: Status] = [:]
    /// The last definitive answer from each source's pinned host and endpoint.
    /// An ordinary reconnect or a failed probe does not erase it. Never persisted.
    @Published private(set) var capabilities: [UUID: LinkedDevicesHostCapabilities] = [:]
    @Published private var probingCapabilities: Set<UUID> = []
    private final class Entry {
        var connection: HubConnection
        let transport = LinkedDevicesSourceTransport()
        var task: Task<Void, Never>?
        var live: LinkedDevicesLiveConnection?
        var bridge: PeerLoopbackBridge?
        var activeToken: UUID?
        var capabilityTask: Task<Void, Never>?
        var authorizationObserver: UUID?
        var enrollmentToken: UUID?
        var enrollmentExistingSource = false
        var enrollmentTransportLost = false
        var attempt = 0
        var terminal = false
        var enrolling = false
        /// Closes `live` once the app has been in the background for the grace.
        var backgroundClose: Task<Void, Never>?
        var backgroundCloseDue: ContinuousClock.Instant?
        init(connection: HubConnection) { self.connection = connection }
    }

    private var entries: [UUID: Entry] = [:]
    private let identities: LinkedDevicesIdentityStore
    private var connector: (any LinkedDevicesSessionConnecting)?
    private let pathMonitor: NWPathMonitor
    private let makeListener: () -> any PeerLoopbackListening
    private let monitorQueue = DispatchQueue(label: "com.termllm.linked-devices.path")
    private var networkAvailable = true
    private var foreground = true
    /// Sources whose page is capturing the microphone or camera.
    private var capturing: Set<UUID> = []
    private let grace: Duration
    private let now: () -> ContinuousClock.Instant
    private let capabilityResolver: @Sendable (any HubTransport, URL) async -> LinkedDevicesHostCapabilities?

    #if canImport(Security)
    convenience init() {
        let identities = LinkedDevicesIdentityStore()
        let diagnostics = LinkedDevicesDiagnostics.configured()
        self.init(identities: identities,
                  connector: LinkedDevicesConnector(identities: identities, diagnostics: diagnostics))
    }
    #endif

    init(identities: LinkedDevicesIdentityStore,
         connector: (any LinkedDevicesSessionConnecting)?,
         pathMonitor: NWPathMonitor = NWPathMonitor(),
         makeListener: @escaping () -> any PeerLoopbackListening = { PeerNWLoopbackListener() },
         backgroundGrace: Duration = LinkedDevicesRuntime.backgroundGrace,
         now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
         capabilityResolver: @escaping @Sendable (any HubTransport, URL) async -> LinkedDevicesHostCapabilities? = {
             await LinkedDevicesHostCapabilities.resolve(over: $0, mount: $1)
         }) {
        self.capabilityResolver = capabilityResolver
        self.identities = identities
        self.connector = connector
        self.pathMonitor = pathMonitor
        self.makeListener = makeListener
        grace = backgroundGrace
        self.now = now
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in self?.networkChanged(path.status == .satisfied) }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    deinit { pathMonitor.cancel() }

    func setConnector(_ connector: any LinkedDevicesSessionConnecting) {
        self.connector = connector
        reconnectEligibleSources(immediate: true)
    }

    func transport(for connection: HubConnection) -> (any HubTransport)? {
        guard connection.isLinkedDevices else { return nil }
        return entry(for: connection).transport
    }

    func status(for sourceID: UUID) -> Status { statuses[sourceID] ?? .offline }

    /// Match the browser's exact source snapshot, even before SwiftUI has
    /// synchronized a catalog change into the runtime (or vice versa).
    func advertisesDeviceTools(for connection: HubConnection) -> Bool {
        guard let entry = entries[connection.id], !entry.terminal,
              Self.sameCapabilityScope(entry.connection, connection) else { return false }
        if let live = entry.live, live.authorization.current == nil { return false }
        return capabilities[connection.id]?.deviceTools == true
    }

    /// Lets a new chat briefly wait for a cold result without holding up
    /// native navigation or an already-loaded chat.
    func mayResolveInitialDeviceTools(for connection: HubConnection) -> Bool {
        guard let entry = entries[connection.id], !entry.terminal,
              Self.sameCapabilityScope(entry.connection, connection),
              capabilities[connection.id] == nil else { return false }
        return statuses[connection.id] == .connecting || probingCapabilities.contains(connection.id)
    }

    private static func sameCapabilityScope(_ lhs: HubConnection, _ rhs: HubConnection) -> Bool {
        lhs.id == rhs.id && lhs.linkedDevicesHostKey == rhs.linkedDevicesHostKey &&
            lhs.url == rhs.url && lhs.kind == rhs.kind
    }

    private func updateConnection(_ entry: Entry, to connection: HubConnection) {
        if !Self.sameCapabilityScope(entry.connection, connection) { capabilities[connection.id] = nil }
        entry.connection = connection
    }

    private func installCapability(_ endpoint: PeerLoopbackEndpoint, for sourceID: UUID) async {
        let dataStore = WKWebsiteDataStore(forIdentifier: sourceID)
        let barrier = HubWebsiteDataBarrier.shared(for: sourceID)
        await barrier.perform {
            await endpoint.installCapability(in: dataStore.httpCookieStore)
        }
    }

    /// Reinstalls only the capability owned by the still-current bridge. Used
    /// after a source authorization purge during approved re-pair restoration.
    func reinstallCapability(for sourceID: UUID) async -> Bool {
        guard let entry = entries[sourceID], !entry.terminal,
              let endpoint = entry.bridge?.currentEndpoint,
              let token = entry.activeToken else { return false }
        await installCapability(endpoint, for: sourceID)
        return entries[sourceID] === entry && entry.activeToken == token && !entry.terminal &&
            entry.bridge?.currentEndpoint == endpoint
    }

    /// Mirrors the saved catalog. Removed sources lose their runtime,
    /// credentials and isolated browser data. Offline/revoked sources remain.
    func synchronize(_ connections: [HubConnection]) {
        let peers = Dictionary(uniqueKeysWithValues: connections.filter(\.isLinkedDevices).map { ($0.id, $0) })
        for (id, entry) in entries where peers[id] == nil {
            // A brand-new approved grant has no catalog row until enrollment
            // commits. An existing row disappearing during re-pair is explicit
            // invalidation and must cancel rather than resurrect the source.
            if entry.enrolling && !entry.enrollmentExistingSource { continue }
            entries[id] = nil
            statuses[id] = nil
            capabilities[id] = nil
            capturing.remove(id)
            tearDown(entry)
            if let key = hostKey(entry.connection) { identities.removeInBackground(hostKey: key) }
            let store = WKWebsiteDataStore(forIdentifier: id)
            HubWebsiteDataBarrier.shared(for: id).enqueue {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                        continuation.resume()
                    }
                }
            }
        }
        for connection in peers.values {
            let entry = entry(for: connection)
            if entry.connection.linkedDevicesHostKey != connection.linkedDevicesHostKey {
                markTerminal(entry, .identityChanged)
                continue
            }
            if entry.connection.url != connection.url || entry.connection.kind != connection.kind {
                // A changed endpoint cannot inherit an in-flight start/bridge
                // or the previous endpoint's advertisement.
                capabilities[connection.id] = nil
                tearDownConnection(entry)
            }
            entry.connection = connection
            startIfEligible(entry, immediate: true)
        }
    }

    func setForeground(_ value: Bool) {
        guard foreground != value else { return }
        foreground = value
        if value {
            let returned = now()
            for entry in entries.values {
                let overdue = entry.backgroundCloseDue.map { returned >= $0 } ?? false
                cancelBackgroundClose(entry)
                // The close never ran because the app was suspended past the
                // grace, so the host has most likely dropped this connection.
                // Replace it now rather than wait for WebRTC to notice.
                if overdue, entry.live != nil, !entry.terminal, !entry.enrolling, !retireIfUnauthorized(entry) {
                    tearDownConnection(entry)
                }
            }
            reconnectEligibleSources(immediate: true)
        } else {
            for entry in entries.values {
                entry.task?.cancel()
                entry.task = nil
                if entry.live == nil && !entry.enrolling { entry.activeToken = nil }
                if entry.live == nil && !entry.terminal { statuses[entry.connection.id] = .suspended }
                scheduleBackgroundClose(entry)
            }
        }
    }

    /// The source's page started or stopped capturing the microphone or
    /// camera. A capturing page (a Live call) keeps its connection open in the
    /// background; when it stops there, the grace starts.
    func setMediaCaptureActive(_ active: Bool, for sourceID: UUID) {
        if active {
            capturing.insert(sourceID)
            if let entry = entries[sourceID] { cancelBackgroundClose(entry) }
        } else {
            capturing.remove(sourceID)
            if let entry = entries[sourceID] { scheduleBackgroundClose(entry) }
        }
    }

    private func scheduleBackgroundClose(_ entry: Entry) {
        let sourceID = entry.connection.id
        guard !foreground, entry.live != nil, entry.backgroundClose == nil, !entry.terminal, !entry.enrolling,
              !capturing.contains(sourceID) else { return }
        let token = entry.activeToken
        let grace = grace
        entry.backgroundCloseDue = now() + grace
        entry.backgroundClose = Task { @MainActor [weak self, weak entry] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled, let self, let entry, self.entries[sourceID] === entry, !self.foreground,
                  entry.live != nil, entry.activeToken == token, !self.capturing.contains(sourceID) else { return }
            guard !self.retireIfUnauthorized(entry) else { return }
            self.tearDownConnection(entry)
            self.statuses[sourceID] = .suspended
        }
    }

    private func cancelBackgroundClose(_ entry: Entry) {
        entry.backgroundClose?.cancel()
        entry.backgroundClose = nil
        entry.backgroundCloseDue = nil
    }

    func reconnectNow(_ sourceID: UUID) {
        guard let entry = entries[sourceID], !entry.terminal, !retireIfUnauthorized(entry) else { return }
        tearDownConnection(entry)
        startIfEligible(entry, immediate: true)
    }

    func pair(link: LinkedDevicesPairingLink, deviceName: String,
              catalog: HubConnectionStore,
              sasReady: @escaping @Sendable (String) -> Void) async throws -> HubConnection {
        guard let connector = connector as? LinkedDevicesConnector else {
            throw LinkedDevicesUnavailable(message: "The WebRTC transport is not available in this build.")
        }
        let hostKey = link.hostKey
        let token = UUID()
        let transportState = LinkedDevicesEnrollmentTransportState()
        let paired = try await connector.pair(link: link, deviceName: deviceName, sasReady: sasReady) { [weak self] in
            transportState.markClosed()
            Task { @MainActor [weak self] in
                self?.pairingTransportClosed(hostKey: hostKey, token: token)
            }
        }
        // Once pair_answer is verified the host grant is durable. Enrollment is
        // an independently owned transaction and must finish even if the sheet
        // task is cancelled immediately afterward.
        let enrollment = Task { @MainActor [self] in
            try await enroll(paired, fallbackName: link.hostLabel ?? "Linked host", in: catalog, token: token,
                             initialTransportClosed: transportState.isClosed)
        }
        do {
            return try await enrollment.value
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as LinkedDevicesPairingFailure {
            throw failure
        } catch {
            throw LinkedDevicesPairingFailure(stage: .savingConnection, error: error)
        }
    }

    private func ownsEnrollment(_ entry: Entry, sourceID: UUID, token: UUID) -> Bool {
        entries[sourceID] === entry && entry.enrolling && entry.enrollmentToken == token && !entry.terminal
    }

    /// Reserves runtime ownership, loopback origin and capability cookie before
    /// publishing the catalog entry. A verified grant is always represented,
    /// even when its first transport attempt failed or was cancelled.
    func enroll(_ paired: LinkedDevicesConnector.Paired, fallbackName: String,
                in catalog: HubConnectionStore, token: UUID,
                initialTransportClosed: Bool = false) async throws -> HubConnection {
        let encodedKey = LinkedDevicesBase64URL.encode(paired.credential.hostKey)
        let existing = catalog.connections.first { $0.linkedDevicesHostKey == encodedKey }
        let sourceID = existing?.id ?? UUID()
        let preferred = existing?.url.port.flatMap { UInt16(exactly: $0) }
        let basePath = paired.credential.basePath ?? "/"
        let normalized = basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = normalized.isEmpty ? "/" : "/" + normalized + "/"
        let name = paired.credential.hostLabel?.isEmpty == false ? paired.credential.hostLabel! : fallbackName
        guard let provisionalURL = existing?.url ?? HubConnectionStore.canonicalLinkedDevicesBridgeURL(
            "http://localhost:\(preferred ?? 1024)\(path)") else {
            paired.live?.close()
            throw LinkedDevicesUnavailable(message: "The linked browser origin is invalid.")
        }

        let provisional = HubConnection(id: sourceID, name: name, kind: .directNode, url: provisionalURL,
                                        needsKindReview: nil, linkedDevicesHostKey: encodedKey)
        let reservedEntry = entry(for: provisional)
        tearDownConnection(reservedEntry)
        updateConnection(reservedEntry, to: provisional)
        reservedEntry.enrolling = true
        reservedEntry.enrollmentToken = token
        reservedEntry.enrollmentExistingSource = existing != nil
        reservedEntry.enrollmentTransportLost = initialTransportClosed
        reservedEntry.terminal = false
        reservedEntry.activeToken = token

        var enrollmentLive = paired.live
        var pendingBridge: PeerLoopbackBridge?
        var stage = LinkedDevicesPairingFailure.Stage.startingLocalBridge
        do {
            while true {
                stage = .startingLocalBridge
                guard ownsEnrollment(reservedEntry, sourceID: sourceID, token: token) else {
                    throw CancellationError()
                }
                if let live = enrollmentLive,
                   reservedEntry.enrollmentTransportLost || !live.authorization.check() {
                    live.close()
                    enrollmentLive = nil
                    reservedEntry.enrollmentTransportLost = false
                    continue
                }

                let authorization = enrollmentLive?.authorization ?? PeerAuthorizationState(PeerAuthorization(
                    peerID: encodedKey, sessionID: "offline-\(UUID().uuidString)", expiresAt: .distantFuture,
                    scopePrefix: basePath))
                let forwarder: any PeerHTTPForwarding
                if let live = enrollmentLive { forwarder = live.forwarder }
                else { forwarder = LinkedDevicesOfflineForwarder() }
                let bridge = PeerLoopbackBridge(forwarder: forwarder, authorization: authorization,
                                                listener: makeListener(), cookiePolicy: .isolate,
                                                preferredPort: preferred)
                pendingBridge = bridge
                reservedEntry.bridge = bridge
                reservedEntry.live = enrollmentLive
                let endpoint: PeerLoopbackEndpoint
                do {
                    endpoint = try await bridge.startPaused()
                } catch {
                    if let live = enrollmentLive,
                       reservedEntry.enrollmentTransportLost || !live.authorization.check() {
                        bridge.revoke()
                        live.close()
                        enrollmentLive = nil
                        reservedEntry.bridge = nil
                        reservedEntry.live = nil
                        reservedEntry.enrollmentTransportLost = false
                        pendingBridge = nil
                        continue
                    }
                    throw error
                }
                if let preferred, endpoint.port != preferred {
                    throw LinkedDevicesUnavailable(message: "The saved browser origin could not be restored.")
                }
                guard let url = HubConnectionStore.canonicalLinkedDevicesBridgeURL(
                    "http://localhost:\(endpoint.port)\(path)") else {
                    throw LinkedDevicesUnavailable(message: "The linked browser origin is invalid.")
                }
                guard ownsEnrollment(reservedEntry, sourceID: sourceID, token: token) else {
                    throw CancellationError()
                }
                if let live = enrollmentLive,
                   reservedEntry.enrollmentTransportLost || !live.authorization.check() {
                    bridge.revoke()
                    live.close()
                    enrollmentLive = nil
                    reservedEntry.bridge = nil
                    reservedEntry.live = nil
                    reservedEntry.enrollmentTransportLost = false
                    pendingBridge = nil
                    continue
                }

                reservedEntry.live = enrollmentLive
                reservedEntry.bridge = bridge
                reservedEntry.task = nil

                await installCapability(endpoint, for: sourceID)
                guard ownsEnrollment(reservedEntry, sourceID: sourceID, token: token) else {
                    throw CancellationError()
                }
                if let live = enrollmentLive,
                   reservedEntry.enrollmentTransportLost || !live.authorization.check() {
                    bridge.revoke()
                    live.close()
                    reservedEntry.bridge = nil
                    reservedEntry.live = nil
                    enrollmentLive = nil
                    reservedEntry.enrollmentTransportLost = false
                    pendingBridge = nil
                    continue
                }
                stage = .activatingLocalBridge
                updateConnection(reservedEntry, to: HubConnection(
                    id: sourceID, name: name, kind: .directNode, url: url,
                    needsKindReview: nil, linkedDevicesHostKey: encodedKey))
                try bridge.activate()
                guard ownsEnrollment(reservedEntry, sourceID: sourceID, token: token) else {
                    throw CancellationError()
                }

                // Existing-source removal during the awaits invalidates this
                // transaction. Never recreate a source the user removed.
                if let existing {
                    guard catalog.connections.contains(where: {
                        $0.id == existing.id && $0.linkedDevicesHostKey == encodedKey
                    }) else { throw CancellationError() }
                }
                stage = .savingCatalog
                let connection = try catalog.saveLinkedDevices(id: sourceID, name: name,
                                                                 hostKey: paired.credential.hostKey,
                                                                 bridgePort: endpoint.port, basePath: basePath)
                guard ownsEnrollment(reservedEntry, sourceID: sourceID, token: token) else {
                    throw CancellationError()
                }
                updateConnection(reservedEntry, to: connection)
                reservedEntry.enrolling = false
                reservedEntry.enrollmentToken = nil
                reservedEntry.enrollmentExistingSource = false
                reservedEntry.enrollmentTransportLost = false
                reservedEntry.attempt = 0
                pendingBridge = nil
                if let live = enrollmentLive {
                    installTransport(live, for: reservedEntry, token: token)
                    // Enrollment may finish after the app went to the background.
                    scheduleBackgroundClose(reservedEntry)
                } else {
                    statuses[sourceID] = .offline
                    startIfEligible(reservedEntry, immediate: true)
                }
                return connection
            }
        } catch {
            pendingBridge?.revoke()
            enrollmentLive?.close()
            let entry = reservedEntry
            guard ownsEnrollment(entry, sourceID: sourceID, token: token) else { throw CancellationError() }
            entry.enrolling = false
            entry.enrollmentToken = nil
            entry.enrollmentExistingSource = false
            entry.enrollmentTransportLost = false
            entry.bridge = nil
            entry.live = nil
            if let existing, let port = existing.url.port.flatMap({ UInt16(exactly: $0) }),
               catalog.connections.contains(where: {
                   $0.id == existing.id && $0.linkedDevicesHostKey == encodedKey
               }) {
                // Re-pairing an existing workspace must never destroy its only
                // visible recovery path. Keep it offline and let normal bounded
                // reconnect restore the same origin.
                let connection = try catalog.saveLinkedDevices(id: existing.id, name: name,
                                                                 hostKey: paired.credential.hostKey,
                                                                 bridgePort: port, basePath: basePath)
                updateConnection(entry, to: connection)
                entry.terminal = false
                entry.activeToken = token
                statuses[sourceID] = .offline
                startIfEligible(entry, immediate: true)
                return connection
            }
            entries[sourceID] = nil
            statuses[sourceID] = nil
            capabilities[sourceID] = nil
            if existing == nil, !catalog.connections.contains(where: { $0.id == sourceID }) {
                try? await identities.removeAsync(hostKey: paired.credential.hostKey)
                // Preserve the safe underlying cause: the generic rollback
                // message used to hide listener and catalog failures entirely.
                throw LinkedDevicesPairingFailure(stage: stage, error: error,
                                                  enrollmentRolledBack: true)
            }
            throw error
        }
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

    /// Handles the production path monitor callback. Internal so lifecycle
    /// regressions can deterministically prove that reachability wakes a
    /// currently armed backoff without mutating the host network.
    func networkChanged(_ available: Bool) {
        guard networkAvailable != available else { return }
        networkAvailable = available
        if available { reconnectEligibleSources(immediate: true) }
        else {
            for entry in entries.values where entry.live == nil && !entry.terminal {
                entry.task?.cancel()
                entry.task = nil
                if !entry.enrolling { entry.activeToken = nil }
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
        let delay: UInt64 = immediate ? 0 : Self.backoffNanoseconds(attempt: entry.attempt)
        let token = UUID()
        // Reserve the attempt before yielding to storage. Foreground/network
        // callbacks must not launch duplicate reads or connection attempts.
        entry.activeToken = token
        statuses[entry.connection.id] = .connecting
        let sourceID = entry.connection.id
        let connection = entry.connection
        entry.task = Task { @MainActor [weak self, weak entry] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard let self, let entry,
                  self.revalidatePendingStart(sourceID: sourceID, token: token, expected: connection,
                                              cancelled: Task.isCancelled),
                  let connector = self.connector else { return }
            let credential: LinkedDevicesCredential
            do { credential = try await self.identities.loadAsync(hostKey: key) }
            catch {
                guard self.revalidatePendingStart(sourceID: sourceID, token: token, expected: connection,
                                                  cancelled: Task.isCancelled) else { return }
                entry.task = nil
                entry.activeToken = nil
                self.statuses[sourceID] = .failed(Self.safeMessage(error))
                return
            }
            // Keychain work cannot be interrupted. Discard its result unless
            // source identity, attempt generation and eligibility still match.
            guard self.revalidatePendingStart(sourceID: sourceID, token: token, expected: connection,
                                              cancelled: Task.isCancelled) else { return }
            guard credential.hostKey == key else {
                self.markTerminal(entry, .identityChanged)
                return
            }
            do {
                let live = try await connector.reconnect(credential: credential) { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.connectionClosed(sourceID: sourceID, token: token)
                    }
                }
                guard !Task.isCancelled, self.entries[sourceID] === entry, entry.activeToken == token else { live.close(); return }
                try await self.attach(live, to: entry, sourceID: sourceID, token: token)
            } catch {
                guard !Task.isCancelled, self.entries[sourceID] === entry, !entry.terminal,
                      entry.activeToken == token else { return }
                entry.task = nil
                if let protocolError = error as? LinkedDevicesProtocolError,
                   protocolError == .hostIdentityChanged || protocolError == .badSignature {
                    self.markTerminal(entry, .identityChanged)
                    return
                }
                if let protocolError = error as? LinkedDevicesProtocolError,
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

    /// Read-only attempt identity and post-await validation are internal so
    /// lifecycle tests can exercise owned-but-ineligible completion directly.
    func pendingStartToken(for sourceID: UUID) -> UUID? {
        guard let entry = entries[sourceID], entry.task != nil else { return nil }
        return entry.activeToken
    }

    func revalidatePendingStart(sourceID: UUID, token: UUID, expected: HubConnection,
                                cancelled: Bool) -> Bool {
        guard let entry = entries[sourceID], owns(entry, sourceID: sourceID, token: token) else { return false }
        guard !cancelled, foreground, networkAvailable, expected.id == sourceID,
              entry.connection.url == expected.url, entry.connection.kind == expected.kind,
              let expectedKey = hostKey(expected), hostKey(entry.connection) == expectedKey else {
            // We still own this reservation, but cannot use it. Never strand it
            // in connecting, and never clear a replacement attempt's state.
            entry.task?.cancel()
            entry.task = nil
            entry.activeToken = nil
            statuses[sourceID] = foreground ? .offline : .suspended
            return false
        }
        return true
    }

    private func owns(_ entry: Entry, sourceID: UUID, token: UUID) -> Bool {
        entries[sourceID] === entry && entry.activeToken == token && !entry.terminal && !entry.enrolling
    }

    private func attach(_ live: LinkedDevicesLiveConnection, to entry: Entry,
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
            await installCapability(endpoint, for: sourceID)
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
            installTransport(live, for: entry, token: token)
        } catch {
            // The bridge can see its first request as soon as it activates,
            // even before the runtime publishes the live transport.
            if owns(entry, sourceID: sourceID, token: token), live.authorization.current == nil {
                capabilities[sourceID] = nil
            }
            bridge.revoke()
            live.close()
            throw error
        }
    }

    private func installTransport(_ live: LinkedDevicesLiveConnection, for entry: Entry, token: UUID) {
        let sourceID = entry.connection.id
        let transport = WebRTCHubTransport(forwarder: live.forwarder, authorization: live.authorization,
                                            hubBaseURL: entry.connection.url)
        entry.transport.install(transport)
        // Local authorization loss retires this transport, not the saved
        // grant. Normal teardown removes the observer before closing.
        entry.authorizationObserver = live.authorization.onRevoke { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let entry = self.entries[sourceID],
                      self.owns(entry, sourceID: sourceID, token: token) else { return }
                self.retireIfUnauthorized(entry)
            }
        }
        refreshCapabilities(entry, over: transport, token: token)
        statuses[sourceID] = .connected(relayed: nil)
        updateSelectedPair(for: entry, live: live)
    }

    /// Each probe is bound to the verified transport that launched it, not the
    /// stable source proxy that can pick up a replacement transport. Only the
    /// current attempt can publish; nil leaves the last definitive answer alone.
    private func refreshCapabilities(_ entry: Entry, over transport: WebRTCHubTransport, token: UUID) {
        let connection = entry.connection
        let sourceID = connection.id
        let resolver = capabilityResolver
        if capabilities[sourceID] == nil { probingCapabilities.insert(sourceID) }
        entry.capabilityTask = Task { @MainActor [weak self, weak entry] in
            guard !Task.isCancelled else { return }
            let result = await resolver(transport, connection.url)
            guard !Task.isCancelled, let self, let entry,
                  self.owns(entry, sourceID: sourceID, token: token),
                  Self.sameCapabilityScope(entry.connection, connection) else { return }
            if let result, entry.live?.authorization.check() == true, self.capabilities[sourceID] != result {
                self.capabilities[sourceID] = result
            }
            self.finishCapabilityProbe(sourceID)
            entry.capabilityTask = nil
        }
    }

    private func finishCapabilityProbe(_ sourceID: UUID) {
        if probingCapabilities.contains(sourceID) { probingCapabilities.remove(sourceID) }
    }

    private func updateSelectedPair(for entry: Entry, live: LinkedDevicesLiveConnection) {
        Task { @MainActor [weak self, weak entry] in
            let stats = await live.stats()
            guard let self, let entry, self.entries[entry.connection.id] === entry,
                  let current = entry.live, current.authorization === live.authorization,
                  current.authorization.check() else { return }
            if let diagnostic = live.diagnostics {
                diagnostic.emit(.candidate(
                    local: .init(stats.localCandidateType), remote: .init(stats.remoteCandidateType)))
            }
            let known = stats.localCandidateType != nil || stats.remoteCandidateType != nil
            self.statuses[entry.connection.id] = .connected(relayed: known ? stats.isRelayed : nil)
        }
    }

    /// Routes the first transport's close independently from enrollment
    /// ownership. Internal so controlled lifecycle tests can deliver the same
    /// callback interleaving as the production connector.
    func pairingTransportClosed(hostKey: Data, token: UUID) {
        guard let entry = entries.values.first(where: { self.hostKey($0.connection) == hostKey }) else { return }
        connectionClosed(entry, token: token)
    }

    private func connectionClosed(sourceID: UUID, token: UUID) {
        // The Sendable SDK callback carries only immutable generation identity.
        // Resolve mutable Entry state after hopping back to the MainActor.
        guard let entry = entries[sourceID], entry.activeToken == token else { return }
        connectionClosed(entry, token: token)
    }

    private func connectionClosed(_ entry: Entry?, token: UUID) {
        guard let entry, entries[entry.connection.id] === entry else { return }
        if entry.enrolling, entry.enrollmentToken == token {
            // The verified enrollment transaction owns catalog publication;
            // loss of only its first transport downgrades it to offline.
            entry.enrollmentTransportLost = true
            return
        }
        guard entry.activeToken == token, !retireIfUnauthorized(entry) else { return }
        tearDownConnection(entry)
        guard !entry.terminal else { return }
        statuses[entry.connection.id] = foreground ? .offline : .suspended
        startIfEligible(entry, immediate: false)
    }

    // The authorization observer and socket-close callback can arrive in
    // either order. Retire this generation and its cached advertisement once.
    // Only the authenticated reconnect path can make revocation terminal.
    @discardableResult
    private func retireIfUnauthorized(_ entry: Entry) -> Bool {
        guard let live = entry.live, live.authorization.current == nil else { return false }
        let sourceID = entry.connection.id
        capabilities[sourceID] = nil
        tearDownConnection(entry)
        statuses[sourceID] = foreground ? .offline : .suspended
        // Back off if a repeatedly accepted peer keeps returning HTTP 401.
        startIfEligible(entry, immediate: false)
        return true
    }

    private func invalidateEnrollment(_ entry: Entry) {
        entry.enrolling = false
        entry.enrollmentToken = nil
        entry.enrollmentExistingSource = false
        entry.enrollmentTransportLost = false
    }

    private func markTerminal(_ entry: Entry, _ status: Status) {
        entry.terminal = true
        invalidateEnrollment(entry)
        tearDownConnection(entry)
        capabilities[entry.connection.id] = nil
        statuses[entry.connection.id] = status
    }

    private func tearDown(_ entry: Entry) {
        entry.terminal = true
        invalidateEnrollment(entry)
        entry.task?.cancel()
        entry.task = nil
        capabilities[entry.connection.id] = nil
        tearDownConnection(entry)
    }

    private func tearDownConnection(_ entry: Entry) {
        entry.task?.cancel()
        entry.task = nil
        cancelBackgroundClose(entry)
        entry.capabilityTask?.cancel()
        entry.capabilityTask = nil
        finishCapabilityProbe(entry.connection.id)
        entry.activeToken = nil
        let live = entry.live
        if let observer = entry.authorizationObserver { live?.authorization.removeHandler(observer) }
        entry.authorizationObserver = nil
        entry.live = nil
        entry.transport.disconnect()
        live?.diagnostics?.emit(.retired)
        entry.bridge?.revoke()
        entry.bridge = nil
        live?.close()
    }

    private func hostKey(_ connection: HubConnection) -> Data? {
        guard let encoded = connection.linkedDevicesHostKey,
              let key = LinkedDevicesBase64URL.decode(encoded, maximumBytes: 32), key.count == 32 else { return nil }
        return key
    }

    static func backoffNanoseconds(attempt: Int) -> UInt64 {
        let seconds = min(30.0, pow(2.0, Double(min(attempt, 5))))
        return UInt64(seconds * 1_000_000_000)
    }

    static func shouldStopAutomatically(_ error: Error) -> Bool {
        switch error {
        case LinkedDevicesBrokerError.superseded, LinkedDevicesBrokerError.rateLimited,
             LinkedDevicesBrokerError.quotaExceeded, LinkedDevicesBrokerError.badRequest,
             LinkedDevicesBrokerError.tooLarge, LinkedDevicesBrokerError.malformed,
             LinkedDevicesBrokerError.invalidAddress, LinkedDevicesProtocolError.invalid(_):
            return true
        default:
            return false
        }
    }

    static func safeMessage(_ error: Error) -> String {
        switch error {
        case let value as LinkedDevicesUnavailable: return value.message
        case LinkedDevicesStorageError.hostMismatch, LinkedDevicesProtocolError.hostIdentityChanged: return "Host identity changed"
        case LinkedDevicesStorageError.missing: return "Linked device credentials are missing. Pair again."
        case LinkedDevicesStorageError.corrupt: return "Linked device credentials are unreadable. Forget the connection and pair again."
        case LinkedDevicesStorageError.unavailable(_): return "Linked device credentials could not be loaded securely. Try connecting again."
        case LinkedDevicesProtocolError.invalid(_): return "The host returned invalid transport data. Connect manually or pair again."
        case let value as LinkedDevicesBrokerError where shouldStopAutomatically(value):
            return value.localizedDescription
        default: return "Linked host is unavailable. It will reconnect without replaying requests."
        }
    }
}
