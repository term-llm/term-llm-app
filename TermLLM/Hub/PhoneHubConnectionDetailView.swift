import SwiftUI

/// One connection’s status and actions, shown from Settings or the Agents banner.
@MainActor
struct PhoneHubConnectionDetailView: View {
    @ObservedObject var source: HubSourceWorkspace
    @ObservedObject var store: HubStore
    @ObservedObject var connections: HubConnectionStore
    @ObservedObject var aggregate: HubAggregateStore
    let onOpenChat: (UUID, URL) -> Void
    var onClose: (() -> Void)? = nil
    @ObservedObject private var linkedDevices = LinkedDevicesRuntime.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editor: PhoneHubView.Editor?
    @State private var showingManage = false
    @State private var showingDirectAuth = false
    @State private var confirmingRemove = false
    @State private var navigationError: String?
    #if os(macOS)
    @State private var copiedAppFolder = false
    #endif

    private var isLinked: Bool { source.connection.isLinkedDevices }
    private var style: PhoneHubConnectionStyle { PhoneHubConnectionStyle(source.connection) }

    var body: some View {
        detailContent
            .confirmationDialog(isLinked ? "Forget \(source.connection.name)?" : "Remove \(source.connection.name)?",
                                isPresented: $confirmingRemove, titleVisibility: .visible) {
                Button(isLinked ? "Forget Device" : "Remove Connection", role: .destructive) {
                    let id = source.id
                    if let onClose { onClose() } else { dismiss() }
                    connections.remove(id)
                }
                .accessibilityIdentifier("phoneHub.remove.confirm")
            } message: {
                Text(isLinked ? "This app will need to be linked again to use this device."
                     : "Its agents disappear from the app. You can add it again later.")
            }
            .sheet(item: $editor) { editor in
                PhoneHubConnectionEditor(connections: connections, source: editor.source, initialAddress: editor.address, onDone: {})
                    .safeAreaInset(edge: .bottom, spacing: 0) { PhoneHubFixtureBanner() }
            }
            .sheet(isPresented: $showingManage) {
                PhoneHubManageSheet(source: source, closeTitle: "Back to \(source.connection.name)",
                                    onOpen: openDestination, onClose: { showingManage = false })
            }
            .sheet(isPresented: $showingDirectAuth) {
                PhoneHubDirectAuthentication(source: source)
                    .safeAreaInset(edge: .bottom, spacing: 0) { PhoneHubFixtureBanner() }
            }
    }

    @ViewBuilder private var detailContent: some View {
        #if os(macOS)
        macDetail
            .accessibilityIdentifier("phoneHub.connectionDetail")
            .navigationBarBackButtonHidden(true)
            .workspaceTopBar {
                if let onClose {
                    WorkspaceHeader(title: "Connection Details") {
                        Button("Done", action: onClose)
                            .buttonStyle(.bordered)
                            .keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("phoneHub.issueSheet.done")
                    }
                } else {
                    PushedPageHeader(title: "Connection Details") { EmptyView() }
                }
            }
        #else
        List {
            Section { header }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16))
            if let navigationError {
                Section { Text(navigationError).foregroundStyle(.orange) }
            }
            if isLinked { linkedSections } else { serverSections }
            Section { removeButton.frame(maxWidth: .infinity) }
        }
        .settingsPageTitle(source.connection.name)
        .accessibilityIdentifier("phoneHub.connectionDetail")
        #endif
    }

    #if os(macOS)
    private var macDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    PhoneHubConnectionIcon(style: style, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.connection.name).font(.title3.weight(.semibold))
                        Text(connectionSubtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    statusCapsule(PhoneHubConnectionStatus.of(source, linked: linkedDevices), showsFreshness: false)
                        .fixedSize(horizontal: true, vertical: false)
                }

                if let navigationError {
                    Text(navigationError).foregroundStyle(.orange)
                }
                if !isLinked {
                    if store.unauthorized {
                        Text("Sign in to see this server’s agents.").foregroundStyle(.secondary)
                    } else if let error = source.error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if MacLocalNetworkSettingsButton.isAvailable(for: source) {
                    localNetworkRecovery
                }

                HStack(spacing: 8) {
                    if isLinked {
                        linkedReconnectButton
                    } else if store.unauthorized {
                        signInButton
                    } else {
                        retryButton
                        openChatButton
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                VStack(alignment: .leading, spacing: 0) {
                    if !store.unauthorized || isLinked {
                        LabeledContent("Agents", value: agentsSummary)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 36)
                    }
                    if !isLinked {
                        if !store.unauthorized { Divider().padding(.horizontal, 12) }
                        manageButton
                        Divider().padding(.horizontal, 12)
                        addressButton
                    }
                }
                .background {
                    RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1))
                        .allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))

                removeButton
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
    }

    private var localNetworkRecovery: some View {
        VStack(alignment: .leading, spacing: 8) {
            if #available(macOS 27.2, *) {
                Text("Already enabled? If there are several term-llm entries, click + in Local Network. Press ⌘⇧G, paste this app’s folder path, then select term-llm.app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                MacLocalNetworkSettingsButton()
                if #available(macOS 27.2, *) {
                    Button(copiedAppFolder ? "Folder Path Copied" : "Copy App Folder Path") {
                        NativeApp.copy(Bundle.main.bundleURL.deletingLastPathComponent().path)
                        copiedAppFolder = true
                    }
                    .accessibilityIdentifier("phoneHub.copyRunningAppFolder")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    private var connectionSubtitle: String {
        let address = PhoneHubConnectionStyle.address(source.connection)
        return source.connection.name.caseInsensitiveCompare(address) == .orderedSame ? style.title : "\(style.title) · \(address)"
    }
    #else
    private var header: some View {
        let status = PhoneHubConnectionStatus.of(source, linked: linkedDevices)
        return VStack(spacing: 6) {
            PhoneHubConnectionIcon(style: style, size: 64)
            Text(source.connection.name)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .padding(.top, 6)
            Text("\(style.title) · \(PhoneHubConnectionStyle.address(source.connection))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            statusCapsule(status).padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    #endif

    private func statusCapsule(_ status: PhoneHubConnectionStatus, showsFreshness: Bool = true) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().fill(status.color).frame(width: 7, height: 7).opacity(status.tone == .busy ? 0 : 1)
                ProgressView().controlSize(.mini).opacity(status.tone == .busy ? 1 : 0)
            }
            .frame(width: 12, height: 12)
            Group {
                // Freshness only describes data the app could load.
                if showsFreshness, !isLinked, !store.unauthorized, let updated = store.lastNodesRefresh {
                    Text("\(status.text) · \(updated, style: .relative) ago")
                } else {
                    Text(status.text)
                }
            }
            .lineLimit(1)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(status.tone == .neutral ? Color.secondary : status.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill((status.tone == .neutral ? Color.secondary : status.color).opacity(0.14)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(store.nodesLoading ? "phoneHub.nodesLoading.\(source.id.uuidString)" : "phoneHub.syncStatus.\(source.id.uuidString)")
    }

    private var removeButton: some View {
        Button(isLinked ? "Forget Device" : "Remove Connection", role: .destructive) { confirmingRemove = true }
            .accessibilityIdentifier("phoneHub.remove.\(source.id.uuidString)")
    }

    private var signInButton: some View {
        Button("Sign in") { showAuthentication() }
            .accessibilityIdentifier("phoneHub.signIn.\(source.id.uuidString)")
    }

    private var openChatButton: some View {
        Button("Open in Chat") { openDestination(source.connection.url, nodeID: nil) }
            .disabled(!source.isActive)
            .accessibilityIdentifier("phoneHub.openChat.\(source.id.uuidString)")
    }

    private var retryButton: some View {
        Button(source.error == nil ? "Refresh now" : "Retry") { Task { await store.refresh() } }
            .disabled(store.refreshing)
            .accessibilityIdentifier("phoneHub.retry.\(source.id.uuidString)")
    }

    private var manageButton: some View {
        navigationRow(source.connection.kind == .hub ? "Manage server" : "Authentication") { showAuthentication() }
            .accessibilityIdentifier("phoneHub.details.\(source.id.uuidString)")
    }

    private var addressButton: some View {
        navigationRow("Address & name", value: "Edit") { editor = PhoneHubView.Editor(source: source.connection) }
            .accessibilityIdentifier("phoneHub.edit.\(source.id.uuidString)")
    }

    private var linkedReconnectButton: some View {
        Button("Connect now") { linkedDevices.reconnectNow(source.id) }
            .accessibilityIdentifier("phoneHub.retry.\(source.id.uuidString)")
    }

    #if !os(macOS)
    @ViewBuilder private var serverSections: some View {
        if store.unauthorized {
            Section {
                signInButton
            } footer: {
                Text("Sign in to see this server’s agents. Credentials are kept separately for each connection.")
            }
        } else if let error = source.error {
            Section("Last error") {
                Text(error).font(.callout).foregroundStyle(.secondary)
            }
        }
        Section("Server") {
            if !store.unauthorized {
                LabeledContent("Agents", value: agentsSummary)
                openChatButton
                retryButton
            }
            manageButton
            addressButton
        }
    }

    @ViewBuilder private var linkedSections: some View {
        Section("Device") {
            LabeledContent("Agents", value: agentsSummary)
            linkedReconnectButton
        }
    }
    #endif

    private var agentsSummary: String {
        let nodes = store.nodes
        guard store.nodesVerified || !nodes.isEmpty else { return "—" }
        let online = nodes.filter { $0.status.reachable }.count
        return online == nodes.count ? "\(nodes.count) online" : "\(online) of \(nodes.count) online"
    }

    private func navigationRow(_ title: String, value: String? = nil, action: @escaping () -> Void) -> some View {
        #if os(macOS)
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(ConnectionDetailRowStyle())
        #else
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let value { Text(value).foregroundStyle(.secondary) }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        #endif
    }

    private func showAuthentication() {
        if source.connection.kind == .hub { showingManage = true } else { showingDirectAuth = true }
    }

    private func openDestination(_ url: URL, nodeID: String?) {
        switch Self.destination(url, nodeID: nodeID, source: source, aggregate: aggregate) {
        case .ignore: return
        case .unsafe: navigationError = Self.unsafeDestinationMessage
        case .open:
            showingManage = false
            onOpenChat(source.id, url)
        }
    }

    enum Destination { case open, unsafe, ignore }
    static let unsafeDestinationMessage = "The source supplied an unsafe chat path. Navigation blocked."

    /// A Hub page may only open its own root or a path the aggregate resolves
    /// to the same URL for that node.
    static func destination(_ url: URL, nodeID: String?, source: HubSourceWorkspace, aggregate: HubAggregateStore) -> Destination {
        guard source.isActive, !source.store.unauthorized else { return .ignore }
        if nodeID == nil, url == source.connection.url { return .open }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .ignore }
        let path = parts.percentEncodedPath + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
        guard url.scheme == source.connection.url.scheme, url.host == source.connection.url.host, url.port == source.connection.url.port,
              let nodeID, aggregate.destination(path: path, sourceID: source.id, nodeID: nodeID) == url else {
            return .unsafe
        }
        return .open
    }
}

#if os(macOS)
private struct ConnectionDetailRowStyle: ButtonStyle {
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.08 : hovered ? 0.04 : 0))
            .onHover { hovered = $0 }
    }
}
#endif

/// A Hub's own management page, where it also signs in.
@MainActor
struct PhoneHubManageSheet: View {
    @ObservedObject var source: HubSourceWorkspace
    let closeTitle: String
    let onOpen: (URL, String?) -> Void
    let onClose: () -> Void

    var body: some View {
        if let workspace = source.hubWorkspace {
            VStack(spacing: 0) {
                Button(closeTitle, action: onClose)
                    .padding().accessibilityIdentifier("phoneHub.details.close")
                HubView(source: source, workspace: workspace, onOpenChat: { url in
                    onOpen(url, nil)
                }, onOpenNodeChat: { url, nodeID in
                    onOpen(url, nodeID)
                }, onSettings: onClose)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { PhoneHubFixtureBanner() }
        }
    }
}

@MainActor struct PhoneHubDirectAuthentication: View {
    @ObservedObject var source: HubSourceWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var signingIn = false
    @State private var login = NativeLogin()
    var body: some View {
        NavigationStack {
            Form {
                Section(source.connection.name) {
                    Text("Use this Direct Node’s passkey or bearer token. Credentials are isolated from every other connection.")
                    Button("Sign in with passkey") {
                        Task {
                            guard let epoch = await source.prepareAuthentication() else { return }
                            signingIn = true
                            login.cookieSink = source.nativeCookieSink(epoch: epoch)
                            login.signIn(to: source.connection.url) { result in
                                signingIn = false
                                switch result {
                                case .success: Task { await source.authenticationSucceeded(epoch: epoch) }
                                case .failure(let error): source.authenticationError = error.localizedDescription
                                }
                            }
                        }
                    }.disabled(signingIn || PhoneHubFixture.isEnabled)
                    SecureField("Node token", text: $token).accessibilityIdentifier("phoneHub.direct.token")
                    Button("Sign in with token") {
                        let candidate = token
                        token = ""
                        signingIn = true
                        Task { await source.signInWithBearer(candidate); signingIn = false }
                    }.disabled(token.isEmpty || signingIn).accessibilityIdentifier("phoneHub.direct.signIn")
                    if signingIn { ProgressView("Signing in…") }
                    if let error = source.authenticationError { Text(error).foregroundStyle(.orange) }
                }
                Text("Direct nodes do not support Hub node administration, delegation, or Hub credential management here.")
                    .font(.caption).foregroundStyle(.secondary)
            }.navigationTitle("Node Authentication")
                .toolbar { Button("Done") { dismiss() } }
        }
    }
}
