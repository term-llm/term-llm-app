import SwiftUI

/// Saved connections are app configuration, so they live in Settings. The list
/// only shows identity and status; every action lives on a connection's detail
/// page. Which connection Chat shows is navigation state, not a setting here.
@MainActor
struct PhoneHubConnectionsView: View {
    @ObservedObject var connections: HubConnectionStore
    @ObservedObject var aggregate: HubAggregateStore
    /// Opening a chat from a connection leaves Settings.
    let onOpenChat: (UUID, URL) -> Void
    @AppStorage("phoneHub.showOfflineAgents", store: PhoneHubFixture.defaults) private var showOfflineNodes = false
    @State private var editor: PhoneHubView.Editor?
    @State private var showingReset = false

    /// Connections needing the user: unidentified, signed out, failing, or an
    /// unreadable catalog. Badges Settings and its Connections row.
    static func issueCount(connections: HubConnectionStore, aggregate: HubAggregateStore) -> Int {
        connections.connections.filter { $0.needsKindReview == true }.count +
        aggregate.sources.filter { $0.store.unauthorized || $0.error != nil }.count +
        (connections.persistenceError == nil ? 0 : 1)
    }

    private var reviewSources: [HubConnection] { connections.connections.filter { $0.needsKindReview == true } }

    var body: some View {
        List {
            if let error = connections.persistenceError {
                Section {
                    Text(error).foregroundStyle(.orange)
                    Button("Reset unreadable catalog", role: .destructive) { showingReset = true }
                        .accessibilityIdentifier("phoneHub.resetCatalog")
                }
            }
            Section {
                ForEach(reviewSources) { source in
                    Button { editor = PhoneHubView.Editor(source: source) } label: {
                        PhoneHubConnectionRowLabel(
                            name: source.name, style: .init(source), showsChevron: true,
                            subtitle: "Couldn’t identify server · Tap to review", tone: .warning)
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("phoneHub.source.\(source.id.uuidString)")
                    .swipeActions {
                        Button("Remove", role: .destructive) { connections.remove(source.id) }
                            .accessibilityIdentifier("phoneHub.swipeRemove.\(source.id.uuidString)")
                    }
                }
                ForEach(aggregate.sources) { source in
                    NavigationLink {
                        PhoneHubConnectionDetailView(source: source, store: source.store, connections: connections,
                                                     aggregate: aggregate, onOpenChat: onOpenChat)
                    } label: {
                        PhoneHubConnectionRow(source: source, store: source.store)
                    }
                    .accessibilityIdentifier("phoneHub.source.\(source.id.uuidString)")
                    .swipeActions {
                        Button(source.connection.isLinkedDevices ? "Forget" : "Remove", role: .destructive) { connections.remove(source.id) }
                            .accessibilityIdentifier("phoneHub.swipeRemove.\(source.id.uuidString)")
                    }
                }
                if reviewSources.isEmpty && aggregate.sources.isEmpty {
                    Text(AppPlatform.isMac ? "No connections yet. Use + to add a server." : "No connections yet. Tap + to add a server.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Servers")
            } footer: {
                if !(reviewSources.isEmpty && aggregate.sources.isEmpty) {
                    Text("Select a connection to see its status, sign in, or manage it.")
                }
                if AppPlatform.isMac {
                    Text("To link a device on Mac, open the one-use pairing link from the host’s Settings → Linked devices. You don’t need to scan a QR code.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                Toggle("Show offline agents", isOn: $showOfflineNodes)
                    .accessibilityIdentifier("phoneHub.showOfflineAgents")
            } header: {
                Text("Agents")
            } footer: {
                Text("Offline agents can’t be opened. When shown, they appear greyed out in the Agents list.")
            }
        }
        .transaction { $0.animation = nil }
        #if os(macOS)
        .navigationBarBackButtonHidden(true)
        .workspaceTopBar {
            PushedPageHeader(title: "Connections") {
                Button("Add Connection…", systemImage: "plus") { editor = PhoneHubView.Editor() }
                    .accessibilityIdentifier("phoneHub.connections.add")
            }
        }
        #else
        .navigationTitle("Connections")
        .inlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Connection", systemImage: "plus") { editor = PhoneHubView.Editor() }
                    .accessibilityIdentifier("phoneHub.connections.add")
            }
        }
        #endif
        .sheet(item: $editor) { editor in
            PhoneHubConnectionEditor(connections: connections, source: editor.source, initialAddress: editor.address, onDone: {})
                .safeAreaInset(edge: .bottom, spacing: 0) { PhoneHubFixtureBanner() }
        }
        .confirmationDialog("Reset the unreadable catalog?", isPresented: $showingReset, titleVisibility: .visible) {
            Button("Reset saved connections", role: .destructive) { connections.resetUnreadableCatalog() }
        } message: { Text("This explicitly replaces the preserved catalog. You will need to add your connections again.") }
    }
}

/// Observes the source and its store so status changes redraw only this row.
@MainActor
private struct PhoneHubConnectionRow: View {
    @ObservedObject var source: HubSourceWorkspace
    @ObservedObject var store: HubStore
    @ObservedObject private var linkedDevices = LinkedDevicesRuntime.shared

    var body: some View {
        let status = PhoneHubConnectionStatus.of(source, linked: linkedDevices)
        let style = PhoneHubConnectionStyle(source.connection)
        // Problems replace the address; healthy rows keep a stable subtitle.
        let subtitle = status.tone == .warning ? status.text
            : (source.connection.isLinkedDevices ? "\(style.title) · \(status.text)"
               : "\(style.title) · \(PhoneHubConnectionStyle.address(source.connection))")
        PhoneHubConnectionRowLabel(name: source.connection.name, style: style, subtitle: subtitle, tone: status.tone)
    }
}
