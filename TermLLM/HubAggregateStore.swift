import Combine
import Foundation
import WebKit

struct PhoneHubIdentity: Hashable, Sendable {
    let sourceID: UUID
    let nodeID: String
    let sessionID: String
    let key: String
}
struct PhoneHubNode: Identifiable {
    let source: HubConnection
    let node: HubNode
    var id: PhoneHubIdentity { PhoneHubIdentity(sourceID: source.id, nodeID: node.id, sessionID: "", key: "node") }
}
struct PhoneHubSession: Identifiable {
    let source: HubConnection
    let node: HubNode
    let session: HubNodeSession
    var id: PhoneHubIdentity { PhoneHubIdentity(sourceID: source.id, nodeID: node.id, sessionID: session.id, key: "session") }
}
struct PhoneHubAttention: Identifiable {
    let source: HubConnection
    let nodeID: String
    let sessionID: String
    let itemKey: String
    let title: String
    let path: String
    let inputRequired: Bool
    let seenRequest: AttentionSeenRequest?
    var id: PhoneHubIdentity {
        PhoneHubIdentity(sourceID: source.id, nodeID: nodeID, sessionID: sessionID, key: itemKey)
    }
}

@MainActor private final class SourceRevocationRelay {
    weak var owner: HubSourceWorkspace?
    func revoke() { owner?.revokeAuthorization() }
}

/// One native store, transport, protected WebKit jar and auth epoch per saved
/// source. The existing HubStore still owns all polling/panel sequencing.
@MainActor
final class HubSourceWorkspace: ObservableObject, Identifiable {
    private(set) var connection: HubConnection
    nonisolated let id: UUID
    let store: HubStore
    let hubWorkspace: HubWorkspace?
    let directClient: DirectNodeClient?
    let security: HubConnectionSecurity?
    @Published private(set) var browserRevoked = false
    @Published private(set) var browserIdentity = UUID()
    @Published private(set) var browserReady = false
    @Published var authenticationError: String?
    private var observation: AnyCancellable?
    private var authObservation: AnyCancellable?
    private var active = true
    private var authenticationEpoch: UInt64 = 0
    private var resetTask: Task<Void, Never>?
    private let relay: SourceRevocationRelay?

    init(connection: HubConnection, bearerStorage: any HubBearerStorage = HubKeychainBearerStorage(), dataStore: WKWebsiteDataStore? = nil, transport: (any HubTransport)? = nil) {
        self.connection = connection
        self.id = connection.id
        let security = HubConnectionSecurity(connection: connection, bearerStorage: bearerStorage, dataStore: dataStore)
        self.security = security
        let relay = SourceRevocationRelay()
        self.relay = relay
        if connection.kind == .hub {
            let client = HubClient(base_url: connection.url, cookie_source: { await security.cookies() }, cookie_sink: { _ in }, transport: transport)
            let workspace = HubWorkspace(client: client, requiresAuthentication: false, onAuthorizationRevoked: { relay.revoke() })
            hubWorkspace = workspace
            store = workspace.store
            directClient = nil
        } else {
            let client = DirectNodeClient(base_url: connection.url, cookie_source: { await security.cookies() }, bearer_source: { await security.bearer }, transport: transport)
            directClient = client
            hubWorkspace = nil
            store = HubStore(client: client)
        }
        relay.owner = self
        installAuthorizationContext()
        HubCookieScopeRegistry.shared.register(security, kind: connection.kind)
        observation = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        authObservation = store.$unauthorized.dropFirst().sink { [weak self] unauthorized in
            guard unauthorized, let self else { return }
            let epoch = self.authenticationEpoch
            Task { @MainActor [weak self] in
                guard let self, self.authenticationEpoch == epoch else { return }
                self.revokeAuthorization()
            }
        }
    }

    /// Inject existing HubServing mocks without network, WK or Keychain effects.
    init(connection: HubConnection, store: HubStore) {
        self.connection = connection
        self.id = connection.id
        self.store = store
        hubWorkspace = nil
        directClient = nil
        security = nil
        relay = nil
        observation = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        authObservation = store.$unauthorized.dropFirst().sink { [weak self] unauthorized in
            guard unauthorized, let self else { return }
            let epoch = self.authenticationEpoch
            Task { @MainActor [weak self] in
                guard let self, self.authenticationEpoch == epoch else { return }
                self.revokeAuthorization()
            }
        }
    }

    func updateMetadata(_ connection: HubConnection) {
        guard active, self.connection.id == connection.id, self.connection.url == connection.url,
              self.connection.kind == connection.kind, self.connection != connection else { return }
        objectWillChange.send()
        self.connection = connection
    }
    var isActive: Bool { active }
    var authEpoch: UInt64 { authenticationEpoch }
    var error: String? { authenticationError ?? store.nodeError ?? store.attentionError }
    func start() {
        guard active else { return }
        store.start()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.prepareBrowserAuthentication()
            guard self.active, !self.browserRevoked else { return }
            self.browserReady = true
        }
    }

    private func installAuthorizationContext() {
        let expected = authenticationEpoch
        if let client = hubWorkspace?.client, let security {
            hubWorkspace?.authenticationSucceeded()
            let securityEpoch = security.epoch
            client.scoped_cookie_importer = { [weak self] cookies, isCurrent in
                guard let self else { throw CancellationError() }
                try await self.saveTransportCookies(cookies, epoch: expected, securityEpoch: securityEpoch, isCurrent: isCurrent)
            }
        }
        directClient?.on_unauthorized = { [weak self] in await self?.revokeAuthorization(expected: expected) }
    }

    func revokeAuthorization(expected: UInt64? = nil) {
        guard expected == nil || expected == authenticationEpoch else { return }
        guard active, !browserRevoked else { return }
        authenticationEpoch &+= 1
        store.purgeOnUnauthorized()
        browserRevoked = true
        browserReady = false
        browserIdentity = UUID()
        guard let security else { return }
        security.nextEpoch()
        installAuthorizationContext()
        let expected = security.epoch
        resetTask = Task { @MainActor in
            guard security.active, security.epoch == expected else { return }
            try? security.setBearer(nil)
            await security.clearData(epoch: expected)
        }
    }

    private func saveTransportCookies(_ cookies: [HTTPCookie], epoch expected: UInt64, securityEpoch: UInt64,
                                      isCurrent: @escaping @Sendable () -> Bool) async throws {
        guard active, expected == authenticationEpoch, isCurrent() else { throw CancellationError() }
        await resetTask?.value
        guard active, expected == authenticationEpoch, let security, isCurrent() else { throw CancellationError() }
        guard await security.saveCookies(cookies, epoch: securityEpoch, isCurrent: isCurrent),
              active, expected == authenticationEpoch, isCurrent() else { throw CancellationError() }
    }

    /// Capture before presenting system sign-in. A removed/edited identity or
    /// an intervening revoke invalidates the handoff, not a different source.
    func nativeCookieSink(epoch: UInt64) -> @MainActor ([HTTPCookie]) async throws -> Void {
        let securityEpoch = security?.epoch
        return { [weak self] cookies in
            guard let self, self.active, self.authenticationEpoch == epoch, let security = self.security else { throw CancellationError() }
            await self.resetTask?.value
            guard self.active, self.authenticationEpoch == epoch else { throw CancellationError() }
            let expectedName = self.connection.kind == .hub ? "term_llm_hub_session" : "term_llm_web_session"
            guard !cookies.isEmpty, cookies.allSatisfy({
                $0.name == expectedName && $0.domain.lowercased() == self.connection.url.host?.lowercased() &&
                    $0.path == self.connection.mountPath &&
                    ($0.isSecure || (self.connection.url.scheme == "http" && ServerAddress.allowsLocalHTTP(host: self.connection.url.host ?? ""))) &&
                    ($0.expiresDate.map { $0 > Date() } ?? true)
            }) else { throw CancellationError() }
            guard let securityEpoch else { throw CancellationError() }
            if self.connection.kind == .directNode {
                try security.setBearer(nil)
                guard await security.clearData(epoch: securityEpoch) else { throw CancellationError() }
            }
            guard self.active, self.authenticationEpoch == epoch,
                  await security.saveCookies(cookies, epoch: securityEpoch),
                  self.active, self.authenticationEpoch == epoch else { throw CancellationError() }
        }
    }

    func prepareAuthentication() async -> UInt64? {
        guard active else { return nil }
        await resetTask?.value
        guard active else { return nil }
        authenticationEpoch &+= 1
        // An explicit identity change closes the old protected document and
        // native cache immediately, even if the new login is later cancelled.
        browserRevoked = true
        browserReady = false
        browserIdentity = UUID()
        store.purgeOnUnauthorized()
        security?.nextEpoch()
        do { try security?.setBearer(nil) }
        catch { authenticationError = error.localizedDescription; return nil }
        installAuthorizationContext()
        let expected = authenticationEpoch
        await security?.waitForCookies()
        guard active, authenticationEpoch == expected else { return nil }
        if let security { guard await security.clearData(epoch: security.epoch) else { return nil } }
        guard active, authenticationEpoch == expected else { return nil }
        return expected
    }

    @discardableResult
    func authenticationSucceeded(epoch: UInt64) async -> Bool {
        guard active, epoch == authenticationEpoch else { return false }
        await security?.waitForCookies()
        guard active, epoch == authenticationEpoch else { return false }
        authenticationEpoch &+= 1
        security?.nextEpoch()
        security?.authorizeCookieReads()
        installAuthorizationContext()
        let current = authenticationEpoch
        browserRevoked = false
        browserReady = true
        browserIdentity = UUID()
        authenticationError = nil
        await store.resumeAfterAuthentication()
        return active && authenticationEpoch == current && !store.unauthorized
    }

    func signInWithBearer(_ token: String) async {
        guard let epoch = await prepareAuthentication(), let directClient, let security else { return }
        do {
            _ = try await directClient.validate_bearer(token: token)
            guard active, epoch == authenticationEpoch else { return }
            try security.setBearer(token)
            await prepareBrowserAuthentication()
            await authenticationSucceeded(epoch: epoch)
        } catch {
            guard active, epoch == authenticationEpoch else { return }
            authenticationError = error.localizedDescription
        }
    }

    func prepareBrowserAuthentication() async {
        guard active, connection.kind == .directNode, let security, let token = security.bearer else { return }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        if let cookie = HTTPCookie(properties: [.name: "term_llm_token", .value: token.addingPercentEncoding(withAllowedCharacters: allowed) ?? "",
                                               .domain: connection.url.host!, .path: connection.mountPath,
                                               .secure: connection.url.scheme == "https" ? "TRUE" : "FALSE"]) {
            await security.saveCookies([cookie], epoch: security.epoch)
        }
    }

    func dispose(removeCredentials: Bool) {
        guard active else { return }
        active = false
        authenticationEpoch &+= 1
        resetTask?.cancel()
        observation = nil
        authObservation = nil
        hubWorkspace?.client.scoped_cookie_importer = nil
        hubWorkspace?.dispose()
        directClient?.on_unauthorized = nil
        store.purgeOnUnauthorized()
        store.dispose()
        if let security { HubCookieScopeRegistry.shared.unregister(security) }
        security?.dispose(removeCredentials: removeCredentials)
        browserRevoked = true
        browserReady = false
        browserIdentity = UUID()
    }
}

/// Computed projections, not another polling framework. Each existing store
/// publishes immediately, without awaiting any sibling source or panel.
@MainActor
final class HubAggregateStore: ObservableObject {
    @Published private(set) var sources: [HubSourceWorkspace] = []
    private var observations: [UUID: AnyCancellable] = [:]
    private let makeSource: @MainActor (HubConnection) -> HubSourceWorkspace

    init(makeSource: @escaping @MainActor (HubConnection) -> HubSourceWorkspace = { connection in
        HubSourceWorkspace(connection: connection, bearerStorage: PhoneHubFixture.isEnabled ? HubMemoryBearerStorage() : HubKeychainBearerStorage())
    }) { self.makeSource = makeSource }

    func synchronize(_ connections: [HubConnection]) {
        let old = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        for source in sources where !connections.contains(where: { $0.id == source.id && $0.url == source.connection.url && $0.kind == source.connection.kind }) {
            source.dispose(removeCredentials: true)
            observations[source.id] = nil
        }
        let updated = connections.map { connection in
            if let source = old[connection.id], source.isActive {
                source.updateMetadata(connection)
                return source
            }
            let source = makeSource(connection)
            observations[connection.id] = source.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            source.start()
            return source
        }
        if sources.count != updated.count || zip(sources, updated).contains(where: { $0 !== $1 }) {
            sources = updated
        }
    }
    func source(_ id: UUID) -> HubSourceWorkspace? { sources.first { $0.id == id } }
    func refresh() {
        // Fire independently. A slow/offline source never delays the home UI.
        for source in sources { Task { await source.store.refresh() } }
    }

    /// Keep pull-to-refresh visible until its requests finish. Each source still
    /// publishes results independently, so healthy results appear immediately.
    func refreshAndWait() async {
        let tasks = sources.map { source in Task { await source.store.refresh() } }
        for task in tasks { await task.value }
    }
    var nodes: [PhoneHubNode] {
        sources.flatMap { source in
            guard source.store.nodesVerified, !source.store.unauthorized else { return [PhoneHubNode]() }
            return source.store.nodes.map { PhoneHubNode(source: source.connection, node: $0) }
        }
    }
    var sessions: [PhoneHubSession] {
        nodes.flatMap { row in
            HubNavigation.nodeSessions(row.node).map { PhoneHubSession(source: row.source, node: row.node, session: $0) }
        }
    }
    /// Needs-input plus unseen totals from verified sources, not the loaded
    /// attention window (which may be paginated). Ordinary refreshes retain the
    /// last verified totals. nil means no source has reported a result yet.
    var attentionBadgeCount: Int? {
        guard !sources.isEmpty else { return 0 }
        var hasResult = false
        var count = 0
        for source in sources {
            if source.store.unauthorized {
                hasResult = true
                continue
            }
            guard source.store.attentionVerified else { continue }
            hasResult = true
            for value in [source.store.totalInputRequired, source.store.totalUnseen] {
                let (sum, overflow) = count.addingReportingOverflow(max(0, value))
                count = overflow ? Int.max : sum
            }
        }
        return hasResult ? count : nil
    }

    var attention: [PhoneHubAttention] {
        sources.flatMap { source in
            guard source.store.attentionVerified, !source.store.unauthorized else { return [PhoneHubAttention]() }
            let connection = source.connection
            let required = source.store.inputRequired.map { item in
                PhoneHubAttention(source: connection, nodeID: item.node_id, sessionID: item.session_id,
                                  itemKey: "input", title: item.title, path: item.resume_path, inputRequired: true, seenRequest: nil)
            }
            let unseen = source.store.inbox.map { item in
                PhoneHubAttention(source: connection, nodeID: item.node_id, sessionID: item.session_id,
                                  itemKey: "unseen.\(item.store_instance_id ?? "").\(item.attention_seq)", title: item.title,
                                  path: item.resume_path, inputRequired: false,
                                  seenRequest: item.store_instance_id.map { AttentionSeenRequest(store_instance_id: $0, session_id: item.session_id, attention_seq: item.attention_seq) })
            }
            return required + unseen
        }
    }

    func destination(path: String, sourceID: UUID, nodeID: String) -> URL? {
        guard let source = source(sourceID), !source.store.unauthorized, source.isActive else { return nil }
        return HubNavigation.chatDestination(path, server: source.connection.url, nodeID: nodeID, direct: source.connection.kind == .directNode)
    }
}
