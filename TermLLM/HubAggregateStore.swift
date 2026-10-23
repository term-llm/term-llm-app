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

    init(connection: HubConnection, bearerStorage: any HubBearerStorage = HubKeychainBearerStorage(), dataStore: WKWebsiteDataStore? = nil) {
        self.connection = connection
        self.id = connection.id
        let security = HubConnectionSecurity(connection: connection, bearerStorage: bearerStorage, dataStore: dataStore)
        self.security = security
        let relay = SourceRevocationRelay()
        self.relay = relay
        if connection.kind == .hub {
            let client = HubClient(base_url: connection.url, cookie_source: { await security.cookies() }, cookie_sink: { cookies in
                await relay.owner?.saveTransportCookies(cookies)
            })
            let workspace = HubWorkspace(client: client, requiresAuthentication: false, onAuthorizationRevoked: { relay.revoke() })
            hubWorkspace = workspace
            store = workspace.store
            directClient = nil
        } else {
            let client = DirectNodeClient(base_url: connection.url, cookie_source: { await security.cookies() }, bearer_source: { await security.bearer })
            directClient = client
            hubWorkspace = nil
            store = HubStore(client: client)
            client.on_unauthorized = { await relay.revoke() }
        }
        relay.owner = self
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
              self.connection.kind == connection.kind else { return }
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

    func revokeAuthorization() {
        guard active, !browserRevoked else { return }
        authenticationEpoch &+= 1
        if let directClient, let relay { directClient.on_unauthorized = { await relay.revoke() } }
        store.purgeOnUnauthorized()
        browserRevoked = true
        browserReady = false
        browserIdentity = UUID()
        guard let security else { return }
        security.nextEpoch()
        let expected = security.epoch
        resetTask = Task { @MainActor in
            guard security.active, security.epoch == expected else { return }
            try? security.setBearer(nil)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                security.dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { continuation.resume() }
            }
        }
    }

    private func saveTransportCookies(_ cookies: [HTTPCookie]) async {
        let epoch = authenticationEpoch
        await resetTask?.value
        guard active, epoch == authenticationEpoch, let security else { return }
        await security.saveCookies(cookies, epoch: security.epoch)
    }

    /// Capture before presenting system sign-in. A removed/edited identity or
    /// an intervening revoke invalidates the handoff, not a different source.
    func nativeCookieSink(epoch: UInt64) -> @MainActor ([HTTPCookie]) async throws -> Void {
        { [weak self] cookies in
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
            if self.connection.kind == .directNode {
                try security.setBearer(nil)
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    security.dataStore.removeData(ofTypes: [WKWebsiteDataTypeLocalStorage], modifiedSince: .distantPast) { continuation.resume() }
                }
                let oldCookies = await security.cookies()
                for cookie in oldCookies where cookie.name == "term_llm_token" {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        security.dataStore.httpCookieStore.delete(cookie) { continuation.resume() }
                    }
                }
            }
            guard self.active, self.authenticationEpoch == epoch else { throw CancellationError() }
            await security.saveCookies(cookies, epoch: security.epoch)
        }
    }

    func prepareAuthentication() async -> UInt64? {
        await resetTask?.value
        guard active else { return nil }
        return authenticationEpoch
    }

    /// HubView already advances its concrete client callback and resumes the
    /// shared store. Only restore this connection's browser identity here.
    func hubDetailAuthenticationSucceeded() {
        guard active else { return }
        authenticationEpoch &+= 1
        browserRevoked = false
        browserReady = true
        browserIdentity = UUID()
        authenticationError = nil
    }

    func authenticationSucceeded(epoch: UInt64) async {
        guard active, epoch == authenticationEpoch else { return }
        authenticationEpoch &+= 1
        hubWorkspace?.authenticationSucceeded()
        if let directClient, let relay {
            directClient.on_unauthorized = { await relay.revoke() }
        }
        browserRevoked = false
        browserReady = true
        browserIdentity = UUID()
        authenticationError = nil
        await store.resumeAfterAuthentication()
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
        sources = connections.map { connection in
            if let source = old[connection.id], source.isActive {
                source.updateMetadata(connection)
                return source
            }
            let source = makeSource(connection)
            observations[connection.id] = source.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            source.start()
            return source
        }
    }
    func source(_ id: UUID) -> HubSourceWorkspace? { sources.first { $0.id == id } }
    func refresh() {
        // Fire independently. A slow/offline source never delays the home UI.
        for source in sources { Task { await source.store.refresh() } }
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
