import SwiftUI
import WebKit
import Combine

/// Retains the transport, its revocation callback and its store as one identity.
/// SwiftUI may reconstruct HubView values without replacing this StateObject.
@MainActor
final class HubWorkspace: ObservableObject {
    let client: HubClient
    let store: HubStore
    private var observation: AnyCancellable?
    private var isActive = true
    private var authorizationEpoch: UInt64 = 0
    private let onAuthorizationRevoked: @MainActor () -> Void

    init(client: HubClient, requiresAuthentication: Bool, onAuthorizationRevoked: @escaping @MainActor () -> Void) {
        self.client = client
        self.onAuthorizationRevoked = onAuthorizationRevoked
        let store = HubStore(client: client)
        self.store = store
        if requiresAuthentication { store.purgeOnUnauthorized() }
        installAuthorizationCallback()
        observation = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    private func installAuthorizationCallback() {
        let epoch = authorizationEpoch
        client.onUnauthorized = { [weak self] in await self?.revokeAuthorization(epoch: epoch) }
    }

    /// Called only after a successful native session/token import. Old request
    /// callbacks must be rejected again on MainActor, not just before an await.
    func authenticationSucceeded() {
        guard isActive else { return }
        authorizationEpoch &+= 1
        installAuthorizationCallback()
    }

    private func revokeAuthorization(epoch: UInt64) {
        guard isActive, epoch == authorizationEpoch else { return }
        authorizationEpoch &+= 1
        installAuthorizationCallback()
        store.purgeOnUnauthorized()
        onAuthorizationRevoked()
    }

    func dispose() {
        isActive = false
        authorizationEpoch &+= 1
        client.onUnauthorized = nil
        store.dispose()
    }
}

/// The Hub is a native sibling of chat, never a page inside its WebView.
@MainActor
struct HubView: View {
    let server: URL
    let onOpenChat: (URL) -> Void
    let onSettings: () -> Void
    let onAuthorizationRevoked: @MainActor () -> Void
    let onAuthenticated: () -> Void
    @StateObject private var workspace: HubWorkspace
    private var ownsWorkspace = true
    private var source: HubSourceWorkspace?
    private var onOpenNodeChat: ((URL, String) -> Void)?
    private var store: HubStore { workspace.store }
    private var client: HubClient { workspace.client }
    @State private var tab: Panel = .nodes
    @State private var showOfflineNodes = false
    @State private var configuration: HubPageConfiguration?
    @State private var configurationError: String?
    @State private var token = ""
    @State private var signingIn = false
    @State private var login = NativeLogin()
    @State private var nodeName = ""
    @State private var nodeURL = ""
    @State private var nodeToken = ""
    @State private var revealRegistration = false
    @State private var credentialName = ""
    @State private var renaming: HubCredential?
    @State private var removingNode: HubNode?
    @State private var orderError: String?
    @State private var navigationError: String?
    @Environment(\.scenePhase) private var scenePhase

    enum Panel: String, CaseIterable, Identifiable {
        case nodes = "Nodes", attention = "Attention", delegations = "Delegations", management = "Manage", security = "Security"
        var id: String { rawValue }
        var identifier: String {
            switch self {
            case .nodes: "hub.nodes"
            case .attention: "hub.attention"
            case .delegations: "hub.delegations"
            case .management: "hub.management"
            case .security: "hub.security"
            }
        }
    }

    init(server: URL, onOpenChat: @escaping (URL) -> Void, onSettings: @escaping () -> Void,
         requiresAuthentication: Bool = false,
         onAuthorizationRevoked: @escaping @MainActor () -> Void = {}, onAuthenticated: @escaping () -> Void = {}) {
        self.server = server
        self.onOpenChat = onOpenChat
        self.onSettings = onSettings
        self.onAuthorizationRevoked = onAuthorizationRevoked
        self.onAuthenticated = onAuthenticated
        let client = HubClient(baseURL: server, cookieSource: {
            await Self.cookies()
        }, cookieSink: { cookies in
            await Self.saveCookies(cookies)
        })
        _workspace = StateObject(wrappedValue: HubWorkspace(client: client, requiresAuthentication: requiresAuthentication, onAuthorizationRevoked: onAuthorizationRevoked))
    }

    /// Phone home retains this workspace across detail presentation. The legacy
    /// standalone initializer above continues to own/dispose its own workspace.
    init(source: HubSourceWorkspace, workspace: HubWorkspace,
         onOpenChat: @escaping (URL) -> Void, onOpenNodeChat: @escaping (URL, String) -> Void,
         onSettings: @escaping () -> Void) {
        self.server = source.connection.url
        self.source = source
        self.onOpenChat = onOpenChat
        self.onOpenNodeChat = onOpenNodeChat
        self.onSettings = onSettings
        self.onAuthorizationRevoked = {}
        self.onAuthenticated = {}
        self.ownsWorkspace = false
        _workspace = StateObject(wrappedValue: workspace)
        _tab = State(initialValue: .management)
    }

    @MainActor private static func cookies() async -> [HTTPCookie] {
        let jar = HubFixture.isEnabled ? HubFixture.websiteDataStore.httpCookieStore : WKWebsiteDataStore.default().httpCookieStore
        return await withCheckedContinuation { continuation in
            jar.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    @MainActor private static func saveCookies(_ cookies: [HTTPCookie]) async {
        let jar = HubFixture.isEnabled ? HubFixture.websiteDataStore.httpCookieStore : WKWebsiteDataStore.default().httpCookieStore
        for cookie in cookies {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if let expiry = cookie.expiresDate, expiry <= Date() {
                    jar.delete(cookie) { continuation.resume() }
                } else { jar.setCookie(cookie) { continuation.resume() } }
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(Panel.allCases) { panel in
                            Button(panel.rawValue) { tab = panel }
                                .buttonStyle(.bordered)
                                .tint(tab == panel ? .cyan : .secondary)
                                .accessibilityIdentifier(panel.identifier)
                        }
                    }.padding(.horizontal).padding(.vertical, 8)
                }
                .accessibilityIdentifier("hub.panelStrip")
                if store.unauthorized {
                    authentication
                } else {
                    List {
                        if let error = configurationError { status(error, error: true) }
                        if let error = navigationError { status(error, error: true) }
                        switch tab {
                        case .nodes: nodesPanel
                        case .attention: attentionPanel
                        case .delegations: delegationsPanel
                        case .management: managementPanel
                        case .security: securityPanel
                        }
                    }
                    .platformInsetGroupedListStyle()
                    .transaction { $0.animation = nil }
                    .refreshable { await store.refresh() }
                }
            }
            .navigationTitle(source?.connection.name ?? "Hub")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .platformTrailing) {
                    Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh Hub")
                        .accessibilityIdentifier("hub.refresh")
                }
            }
            .task {
                store.start()
                await discover()
            }
            .task(id: tab) {
                if tab == .management { await store.loadRegistrationInfo() }
                if tab == .security, configuration?.passkeyAuth == true { await store.loadSecurity() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { store.suspendPolling() }
                if phase == .active {
                    store.resumePolling()
                    Task { await store.refresh() }
                }
            }
            .alert("Rename passkey", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Passkey name", text: $credentialName)
                Button("Save") {
                    if let credential = renaming {
                        Task { await store.renameCredential(recordID: credential.recordID, displayName: credentialName) }
                    }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .confirmationDialog("Remove node?", isPresented: Binding(get: { removingNode != nil }, set: { if !$0 { removingNode = nil } }), titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    if let node = removingNode { Task { await store.removeNode(id: node.id) } }
                    removingNode = nil
                }
            } message: { Text("Remove this saved node from the Hub? The node itself is not stopped.") }
        }
        .onDisappear { if ownsWorkspace { workspace.dispose() } }
        .onChange(of: store.unauthorized) { _, unauthorized in
            if unauthorized { onAuthorizationRevoked() }
        }
    }

    private func panelRefreshStatus(loading: Bool, verified: Bool, title: String) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary).opacity(loading ? 0 : 1)
                ProgressView().controlSize(.small).opacity(loading ? 1 : 0)
            }
            .frame(width: 18, height: 18)
            Text(loading ? "Updating \(title.lowercased())…" : (verified ? "\(title) updated" : "Waiting for \(title.lowercased())…"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    @ViewBuilder private var nodesPanel: some View {
        let offlineCount = store.nodes.filter { !$0.status.reachable }.count
        let visibleNodes = store.nodes.filter { showOfflineNodes || $0.status.reachable }
        Section {
            HStack {
                Text(showOfflineNodes ? "All nodes" : "Online nodes")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if offlineCount > 0 || showOfflineNodes {
                    Button(showOfflineNodes ? "Online only" : "Show all (\(offlineCount) offline)") {
                        showOfflineNodes.toggle()
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("hub.nodes.showAll")
                    .accessibilityValue(showOfflineNodes ? "All nodes" : "Online only")
                }
            }
            .frame(minHeight: 44)
            LabeledContent("Active sessions", value: "\(store.activeSessionCount)")
            panelRefreshStatus(loading: store.nodesLoading, verified: store.nodesVerified, title: "Nodes")
            if let error = store.nodeError { status(error, error: true) }
            if let warning = store.resolverWarning, !warning.isEmpty { status(warning, error: true) }
            if !store.nodesVerified && !store.nodes.isEmpty { status("Last known nodes · updating") }
        }
        ForEach(visibleNodes, id: \.id) { node in
            Section {
                NavigationLink {
                    nodeDetails(node)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: node.status.reachable ? "circle.fill" : "circle")
                                .foregroundStyle(node.status.reachable ? .green : .secondary)
                            Text(node.name).font(.headline)
                            Spacer()
                            Text(node.status.state).font(.caption)
                        }
                        Text("\(node.source) · \(node.connection) · \(node.status.latencyMs) ms")
                            .font(.caption).foregroundStyle(.secondary)
                        if let sessions = node.sessions { Text(sessions.countLabel).font(.subheadline) }
                        if let error = node.status.error, !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange) }
                    }
                }
                .accessibilityIdentifier("hub.node.\(node.id)")
                Button("New conversation", systemImage: "plus.bubble") { open(node.newSessionPath, nodeID: node.id) }
                    .disabled(!node.status.reachable || !store.nodesVerified)
                ForEach(HubNavigation.nodeSessions(node).prefix(4), id: \.id) { session in
                    sessionButton(session, node: node)
                }
            }
        }
        if visibleNodes.isEmpty && !store.nodesLoading && store.nodeError == nil {
            Section {
                Text(store.nodes.isEmpty ? "No nodes found. Add a server in Manage, or check your Hub resolver." : "No nodes online. Use Show all to see offline nodes.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func nodeDetails(_ node: HubNode) -> some View {
        List {
            Section("Connection") {
                LabeledContent("Status", value: node.status.state)
                LabeledContent("Source", value: node.source)
                LabeledContent("Connection", value: node.connection)
                LabeledContent("Latency", value: "\(node.status.latencyMs) ms")
                if let version = node.status.version { LabeledContent("Version", value: version) }
                if let agent = node.status.agent { LabeledContent("Agent", value: agent) }
                Text(node.url).font(.caption).textSelection(.enabled)
                if let error = node.status.error { status(error, error: true) }
                ForEach(Array((node.diagnostics ?? []).enumerated()), id: \.offset) { _, diagnostic in
                    status("\(diagnostic.severity): \(diagnostic.message)", error: true)
                }
            }
            Section("Sessions") {
                Button("New conversation", systemImage: "plus.bubble") { open(node.newSessionPath, nodeID: node.id) }
                    .disabled(!node.status.reachable)
                ForEach(HubNavigation.nodeSessions(node), id: \.id) { session in sessionButton(session, node: node) }
                if node.sessions?.hasMore == true, let path = node.sessions?.resumePath {
                    Button("All sessions in chat") { open(path, nodeID: node.id) }
                }
                if HubNavigation.nodeSessions(node).isEmpty { Text("No recent sessions") }
            }.accessibilityIdentifier("hub.sessions")
        }
        .navigationTitle(node.name)
        .toolbar { ToolbarItem(placement: .platformTrailing) { HubBackButton() } }
    }

    private func sessionButton(_ session: HubNodeSession, node: HubNode) -> some View {
        Button { open(session.resumePath, nodeID: node.id) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.shortTitle.isEmpty ? (session.number.map { "Session \($0)" } ?? session.id) : session.shortTitle)
                HStack {
                    if session.pinned == true { Image(systemName: "pin.fill") }
                    if session.interactionRequired == true { Text("Needs input") }
                    else if session.activeRun == true { Text("Running") }
                    if let count = session.messageCount { Text("\(count) messages") }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(!node.status.reachable || !store.nodesVerified)
        .accessibilityIdentifier("hub.session.open.\(node.id).\(session.id)")
    }

    @ViewBuilder private var attentionPanel: some View {
        Section {
            LabeledContent("Needs input", value: "\(store.totalInputRequired)")
            LabeledContent("Unseen results", value: "\(store.totalUnseen)")
            panelRefreshStatus(loading: store.attentionLoading, verified: store.attentionVerified, title: "Attention")
            if let error = store.attentionError {
                status(error, error: true)
                if !store.inbox.isEmpty || !store.inputRequired.isEmpty { status("Showing the last successful attention result.") }
            }
            if let message = store.attentionClearStatus { status(message) }
            Button("Clear all unseen", role: .destructive) { Task { await store.clearAttention() } }
                .disabled(!store.attentionVerified || store.clearingAttention || store.totalUnseen == 0)
                .accessibilityIdentifier("hub.clearAttention")
        }
        Section("Needs input") {
            ForEach(store.inputRequired, id: \.hubIdentity) { item in
                Button { open(item.resumePath, nodeID: item.nodeID) } label: {
                    VStack(alignment: .leading) {
                        Text(item.title.isEmpty ? item.sessionID : item.title)
                        Text("\(item.nodeName) · \(item.pendingInteractionCount) pending" + (item.stale == true ? " · stale" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if store.inputRequired.isEmpty { Text("No input needed").foregroundStyle(.secondary) }
        }
        Section("Results to review") {
            ForEach(store.inbox, id: \.hubIdentity) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Button { open(item.resumePath, nodeID: item.nodeID) } label: {
                        VStack(alignment: .leading) {
                            Text(item.title.isEmpty ? item.sessionID : item.title)
                            Text("\(item.nodeName) · \(item.outcome)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Mark seen") { Task { await store.markInboxItemSeen(item) } }
                        .font(.caption)
                        .disabled(item.storeInstanceID == nil || !store.attentionVerified || store.markingSeen.contains(HubStore.inboxItemKey(item)))
                }
            }
            if store.inbox.isEmpty { Text("No unseen results").foregroundStyle(.secondary) }
            if store.attentionHasMore {
                if store.canLoadMoreAttention {
                    Button("Load more results") { Task { await store.loadMoreAttention() } }
                        .disabled(store.attentionLoading)
                        .accessibilityIdentifier("hub.loadMore")
                } else { Text("Showing the Hub maximum of 500 results. Clear reviewed results to reveal more.").font(.caption) }
            }
        }
    }

    @ViewBuilder private var delegationsPanel: some View {
        Section {
            LabeledContent("Active", value: "\(store.activeDelegationCount)")
            panelRefreshStatus(loading: store.delegationsLoading, verified: store.delegationsVerified, title: "Delegations")
            if let error = store.delegationError { status(error, error: true) }
        }
        ForEach(store.delegations, id: \.id) { work in
            NavigationLink {
                List {
                    Section("Route") {
                        LabeledContent("From", value: work.originNode)
                        LabeledContent("To", value: work.targetNode)
                        LabeledContent("Status", value: work.status)
                        LabeledContent("Depth", value: "\(work.depth)")
                        if let name = work.agentName { LabeledContent("Agent", value: name) }
                        if let model = work.model { LabeledContent("Model", value: model) }
                        if let cwd = work.cwd { LabeledContent("Directory", value: cwd) }
                        if let job = work.jobID { LabeledContent("Job", value: job) }
                        if let run = work.runID { LabeledContent("Run", value: run) }
                        if let parent = work.parentDelegationID { LabeledContent("Parent", value: parent) }
                        if let chain = work.chain { Text(chain.joined(separator: " → ")) }
                        LabeledContent("Created", value: work.createdAt)
                        LabeledContent("Updated", value: work.updatedAt)
                    }
                    if let prompt = work.prompt { Section("Prompt") { Text(prompt).textSelection(.enabled) } }
                    if let response = work.response { Section("Response") { Text(verbatim: response).textSelection(.enabled) } }
                    if let error = work.error { Section("Error") { status(error, error: true) } }
                }.navigationTitle("Delegation")
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(work.originNode) → \(work.targetNode)").font(.headline)
                    Text(work.status).font(.caption).foregroundStyle(.secondary)
                    if let prompt = work.prompt { Text(prompt).lineLimit(3) }
                    if let job = work.jobID { Text("Job \(job)").font(.caption) }
                }
            }
        }
        if store.delegations.isEmpty && !store.delegationsLoading { Section { Text("No delegated work yet").foregroundStyle(.secondary) } }
    }

    @ViewBuilder private var managementPanel: some View {
        Section("Saved nodes") {
            Text("Reordering moves the listed nodes within their existing dashboard slots. Discovered nodes remain managed by their resolver.").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(store.nodes.enumerated()), id: \.element.id) { index, node in
                HStack {
                    VStack(alignment: .leading) { Text(node.name); Text(node.source).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button { moveNode(index, by: -1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                        .accessibilityLabel("Move \(node.name) up")
                    Button { moveNode(index, by: 1) } label: { Image(systemName: "arrow.down") }.disabled(index == store.nodes.count - 1)
                        .accessibilityLabel("Move \(node.name) down")
                    if node.source == "local" {
                        Button(role: .destructive) { removingNode = node } label: { Image(systemName: "trash") }
                            .accessibilityLabel("Remove \(node.name)")
                    }
                }.buttonStyle(.borderless)
            }
            if let error = orderError { status(error, error: true) }
        }
        Section("Add a server") {
            if configuration?.canAddNodes == false || store.registrationInfo?.canPersistNodes == false {
                Text("This Hub does not support saving nodes. Configure its node store on the host.")
            } else {
                TextField("Name", text: $nodeName).accessibilityIdentifier("hub.nodeName")
                TextField("HTTPS server URL", text: $nodeURL).urlTextEntry().autocorrectionDisabled()
                SecureField("Node token", text: $nodeToken)
                HStack {
                    Button("Test connection") { Task { await store.testNode(nodeForm) } }
                    Spacer()
                    Button("Add node") {
                        Task {
                            if await store.addNode(nodeForm) { nodeName = ""; nodeURL = ""; nodeToken = "" }
                        }
                    }.accessibilityIdentifier("hub.addNode")
                }.disabled(nodeName.trimmingCharacters(in: .whitespaces).isEmpty || ServerAddress.parse(nodeURL) == nil || store.nodeOperation != .idle)
            }
            if let result = store.nodeOperationResult { status(result) }
        }
        Section("Automatic registration") {
            if store.registrationLoading { ProgressView() }
            if let error = store.registrationError { status(error, error: true) }
            if let info = store.registrationInfo {
                Text(info.enabled ? "Node registration is enabled." : "Node registration is disabled.")
                Text("Run term-llm with the Hub URL and registration token on the node host. The app does not run or tunnel nodes.").font(.caption).foregroundStyle(.secondary)
                if let secret = info.registrationToken {
                    Toggle("Reveal registration token", isOn: $revealRegistration)
                    if revealRegistration { Text(secret).font(.system(.caption, design: .monospaced)).textSelection(.enabled).privacySensitive() }
                }
            }
        }
    }

    @ViewBuilder private var securityPanel: some View {
        if configuration?.passkeyAuth == false {
            Section("Authentication") {
                Text(configuration?.authMode == "bearer" ? "This Hub uses a token, not passkeys." : "This Hub does not require sign-in.")
                if configuration?.authMode == "bearer" {
                    Button("Sign out", role: .destructive) {
                        Task { await client.clearLocalAuth(); store.purgeOnUnauthorized() }
                    }.accessibilityIdentifier("hub.signOut")
                }
            }
        } else {
        Section("Passkeys and sessions") {
            LabeledContent("Active sessions", value: "\(store.activeSessions)")
            if store.securityLoading { ProgressView("Loading security…") }
            if let message = store.securityStatus { status(message) }
            ForEach(store.credentials, id: \.recordID) { credential in
                VStack(alignment: .leading, spacing: 6) {
                    Text(credential.displayName).font(.headline)
                    Text("Created \(credential.createdAt)\nLast used \(credential.lastUsedAt)").font(.caption).foregroundStyle(.secondary)
                    Text(credential.transports?.joined(separator: ", ") ?? "Transport not reported").font(.caption)
                    HStack {
                        Button("Rename") { credentialName = credential.displayName; renaming = credential }
                        Spacer()
                        Button("Remove in browser", role: .destructive) { openSecurityInBrowser() }
                            .disabled(store.credentials.count <= 1 || HubFixture.isEnabled)
                    }
                }
            }
            Button("Refresh security") { Task { await store.loadSecurity() } }
            Button("Revoke other sessions", role: .destructive) { Task { await store.revokeOtherSessions() } }
            Button("Sign out", role: .destructive) {
                Task {
                    if configuration?.authMode == "bearer" {
                        await client.clearLocalAuth()
                        await store.refresh()
                    } else { _ = await store.signOut() }
                }
            }.accessibilityIdentifier("hub.signOut")
        }.disabled(store.securityOperation != nil)
        Section("Passkey ceremonies") {
            Text("Passkey creation and recent-authentication operations for arbitrary self-hosted domains need the system browser. iOS does not authorize this app as every server’s relying party. Native sign-in creates a separate session; browser reauthentication does not upgrade this native session.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Open browser Hub → Security") { openSecurityInBrowser() }
                .disabled(HubFixture.isEnabled)
            Text("In the browser Hub, select Security to add a passkey or remove one after reauthentication. There is no dedicated security-operation handoff in this server version.")
                .font(.caption).foregroundStyle(.secondary)
            if store.recentAuthRequired { status("Complete the protected operation in the browser, then refresh this native list. Signing in again here is not a recent-authentication grant.", error: true) }
        }
        }
    }

    private var authentication: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "lock.shield").font(.largeTitle)
                Text("Sign in to Hub").font(.title2.bold())
                Text(server.host ?? server.absoluteString).font(.caption).foregroundStyle(.secondary)
                if let error = configurationError { status(error, error: true) }
                if store.recentAuthRequired {
                    status("This operation needs recent authentication of the same native session. Browser sign-in cannot grant that. Complete the operation in the browser Hub’s Security panel, then sign in here again.", error: true)
                    Button("Open browser Hub → Security") { openSecurityInBrowser() }.disabled(HubFixture.isEnabled)
                }
                if configuration?.authMode == "bearer" {
                    SecureField("Hub token", text: $token).textFieldStyle(.roundedBorder)
                    Button("Sign in with token") {
                        Task {
                            signingIn = true
                            defer { signingIn = false }
                            do {
                                let epoch = await source?.prepareAuthentication()
                                if source != nil, epoch == nil { throw CancellationError() }
                                try await client.loginBearer(token: token)
                                token = ""
                                _ = await completeAuthentication(epoch: epoch)
                            } catch { configurationError = error.localizedDescription }
                        }
                    }.disabled(token.isEmpty || signingIn)
                        .accessibilityIdentifier("hub.signIn")
                } else {
                    Button("Sign in with passkey", action: signIn).disabled(signingIn || HubFixture.isEnabled)
                        .accessibilityIdentifier("hub.signIn")
                }
                if signingIn { ProgressView("Signing in…") }
                Button("Retry discovery") { Task { await discover(); await store.refresh() } }
                Button(source == nil ? "Server settings" : "Connections", action: onSettings)
                Button("Open chat") { onOpenChat(server) }
            }.padding(24).frame(maxWidth: 520).frame(maxWidth: .infinity)
        }
    }

    private var nodeForm: NodeFormData { NodeFormData(name: nodeName, url: nodeURL, token: nodeToken) }

    private func status(_ message: String, error: Bool = false) -> some View {
        Text(message).font(.callout).foregroundStyle(error ? .orange : .secondary)
            .textSelection(.enabled).accessibilityIdentifier(error ? "hub.error" : "hub.status")
    }

    private func discover() async {
        do {
            switch try await client.discover() {
            case .page(let config):
                configuration = config
                store.setAuthMode(HubAuthMode(rawValue: config.authMode) ?? .passkey)
                configurationError = nil
                if tab == .security, config.passkeyAuth { await store.loadSecurity() }
            case .redirect:
                // A passkey Hub redirects its root to the login page until the
                // session signs in. That is the expected sign-in state, not an error.
                store.setAuthMode(.passkey)
                configurationError = nil
            }
        } catch {
            let reason = error.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            configurationError = "Could not read Hub configuration: \(reason). Direct servers can still use Chat."
        }
    }

    private func open(_ path: String, nodeID: String) {
        guard let url = HubNavigation.chatDestination(path, server: server, nodeID: nodeID, direct: false) else {
            navigationError = "The Hub supplied an unsafe or out-of-mount destination. Navigation was blocked."
            return
        }
        if let onOpenNodeChat { onOpenNodeChat(url, nodeID) }
        else { onOpenChat(url) }
    }

    private func moveNode(_ index: Int, by offset: Int) {
        var ids = store.nodes.map(\.id)
        let other = index + offset
        guard ids.indices.contains(other) else { return }
        ids.swapAt(index, other)
        Task {
            do { try await store.reorderNodes(orderedIDs: ids); orderError = nil }
            catch { orderError = error.localizedDescription }
        }
    }

    private func completeAuthentication(epoch: UInt64?) async -> Bool {
        if let source {
            guard let epoch, await source.authenticationSucceeded(epoch: epoch) else { return false }
        } else {
            workspace.authenticationSucceeded()
            await store.resumeAfterAuthentication()
        }
        onAuthenticated()
        return true
    }

    private func signIn() {
        signingIn = true
        configurationError = nil
        Task { @MainActor in
            let epoch = await source?.prepareAuthentication()
            if source != nil, epoch == nil { signingIn = false; return }
            login.cookieSink = epoch.flatMap { source?.nativeCookieSink(epoch: $0) }
            login.signIn(to: server) { result in
                signingIn = false
                switch result {
                case .success:
                    Task {
                        if await completeAuthentication(epoch: epoch) { await discover() }
                    }
                case .failure(let error): configurationError = error.localizedDescription
                }
            }
        }
    }

    private func openSecurityInBrowser() {
        // Pinned Hub has no /auth/security route or security deep link.
        // Open its real dashboard; the user explicitly chooses Security there.
        NativeApp.open(server)
    }
}

/// Read dismiss from the destination's environment, not the dashboard's.
private struct HubBackButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button("Hub") { dismiss() }.accessibilityIdentifier("hub.back")
    }
}
