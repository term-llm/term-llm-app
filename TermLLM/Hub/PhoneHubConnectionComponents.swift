import SwiftUI

/// Visual identity per connection kind, shared by the list and detail page.
struct PhoneHubConnectionStyle {
    let symbol: String
    let colors: [Color]
    let title: String

    init(kind: HubConnection.Kind, linked: Bool) {
        if linked {
            symbol = "laptopcomputer"; title = "Linked device"
            colors = [Color(red: 0.75, green: 0.35, blue: 0.95), Color(red: 0.54, green: 0.27, blue: 0.67)]
        } else if kind == .hub {
            symbol = "server.rack"; title = kind.title
            colors = [Color(red: 0.37, green: 0.36, blue: 0.90), Color(red: 0.21, green: 0.20, blue: 0.64)]
        } else {
            symbol = "dot.radiowaves.left.and.right"; title = kind.title
            colors = [Color(red: 0.19, green: 0.69, blue: 0.78), Color(red: 0.11, green: 0.50, blue: 0.57)]
        }
    }
    init(_ connection: HubConnection) { self.init(kind: connection.kind, linked: connection.isLinkedDevices) }

    /// Address without scheme or trailing slash; linked devices show a key prefix.
    static func address(_ connection: HubConnection) -> String {
        if connection.isLinkedDevices {
            return (connection.linkedDevicesHostKey.map { String($0.prefix(12)) } ?? "unknown identity") + "…"
        }
        var text = connection.url.absoluteString
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) { text.removeFirst(scheme.count) }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

struct PhoneHubConnectionIcon: View {
    let style: PhoneHubConnectionStyle
    var size: CGFloat = 36
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: style.colors, startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: style.symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// Status shown for a connection, in list and detail.
struct PhoneHubConnectionStatus {
    enum Tone { case ok, warning, neutral, busy }
    let text: String
    let tone: Tone

    var color: Color {
        switch tone {
        case .ok: .green
        case .warning: .orange
        case .neutral: .secondary
        case .busy: .blue
        }
    }

    @MainActor
    static func of(_ source: HubSourceWorkspace, linked: LinkedDevicesRuntime) -> Self {
        if source.connection.isLinkedDevices {
            let status = linked.status(for: source.id)
            let tone: Tone = switch status {
            case .connected(_): .ok
            case .connecting: .busy
            case .revoked, .identityChanged, .failed(_): .warning
            case .offline, .suspended: .neutral
            }
            return .init(text: status.label, tone: tone)
        }
        let store = source.store
        if store.unauthorized { return .init(text: "Needs sign-in", tone: .warning) }
        if source.error != nil { return .init(text: "Couldn’t update", tone: .warning) }
        if store.nodesLoading || store.attentionLoading { return .init(text: "Updating…", tone: .busy) }
        if store.nodesVerified && store.attentionVerified { return .init(text: "Up to date", tone: .ok) }
        return .init(text: "Waiting for server…", tone: .neutral)
    }
}

/// A connection that cannot currently show its agents, and the one action
/// most likely to bring it back.
struct PhoneHubConnectionIssue: Identifiable, Equatable {
    enum Action: Equatable {
        case signIn, retry, reconnect, review
        var title: String {
            switch self {
            case .signIn: "Sign In"
            case .retry: "Retry"
            case .reconnect: "Reconnect"
            case .review: "Review"
            }
        }
    }
    let id: UUID
    let name: String
    let message: String
    let action: Action
    let busy: Bool

    @MainActor
    static func of(_ source: HubSourceWorkspace, linked: LinkedDevicesRuntime) -> Self? {
        let store = source.store
        let name = source.connection.name
        if source.connection.isLinkedDevices {
            let status = linked.status(for: source.id)
            switch status {
            case .revoked, .identityChanged:
                return .init(id: source.id, name: name, message: status.label, action: .review, busy: false)
            case .failed(let message):
                return .init(id: source.id, name: name, message: message, action: .reconnect, busy: false)
            case .connected:
                // The device is reachable; only its data failed to load.
                guard let error = source.error else { return nil }
                return .init(id: source.id, name: name, message: error, action: .retry, busy: store.refreshing)
            case .connecting, .offline, .suspended:
                guard source.error != nil else { return nil }
                return .init(id: source.id, name: name, message: "\(status.label). Couldn’t reach this device.",
                             action: .reconnect, busy: status == .connecting)
            }
        }
        if store.unauthorized {
            let message = source.authenticationError.map { "Sign-in failed: \($0)" } ?? "Signed out. Sign in to see its agents."
            return .init(id: source.id, name: name, message: message, action: .signIn, busy: false)
        }
        guard let error = source.error else { return nil }
        return .init(id: source.id, name: name, message: error, action: .retry, busy: store.refreshing)
    }
}

/// Pinned on the Agents home: each connection that is down, with its fix one
/// tap away rather than behind Settings › Connections.
@MainActor
struct PhoneHubConnectionIssuesBanner: View {
    @ObservedObject var aggregate: HubAggregateStore
    @ObservedObject private var linkedDevices = LinkedDevicesRuntime.shared
    /// A banner sign-in in progress shows progress in place of its button.
    var signingInSourceID: UUID? = nil
    /// Opens the issue's fix (sign-in, review) or its connection page.
    let onOpen: (HubSourceWorkspace, PhoneHubConnectionIssue.Action?) -> Void
    let onShowAll: () -> Void
    private static let limit = 3

    var body: some View {
        let issues = aggregate.sources.compactMap { source in
            PhoneHubConnectionIssue.of(source, linked: linkedDevices).map { (source, $0) }
        }
        if !issues.isEmpty {
            VStack(spacing: 8) {
                ForEach(issues.prefix(Self.limit), id: \.1.id) { source, issue in
                    row(source, issue)
                }
                if issues.count > Self.limit {
                    Button("\(issues.count - Self.limit) more in Settings › Connections", action: onShowAll)
                        .font(.footnote)
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("phoneHub.issues.more")
                }
            }
            .phoneHubHomeBanner()
        }
    }

    private func row(_ source: HubSourceWorkspace, _ issue: PhoneHubConnectionIssue) -> some View {
        #if os(macOS)
        let offersSettings = MacLocalNetworkSettingsButton.isAvailable(for: source)
        let message = offersSettings
            ? "Couldn’t reach this server. For a local server, check Privacy & Security → Local Network."
            : issue.message
        #else
        let message = issue.message
        #endif
        return HStack(spacing: 12) {
            Button { onOpen(source, nil) } label: {
                HStack(spacing: 10) {
                    Image(systemName: issue.action == .signIn ? "person.crop.circle.badge.exclamationmark" : "wifi.exclamationmark")
                        .font(.title3)
                        .foregroundStyle(.orange)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                        Text(message).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Shows this connection")
            .accessibilityIdentifier("phoneHub.issue.\(issue.id.uuidString)")
            #if os(macOS)
            if offersSettings {
                MacLocalNetworkSettingsButton()
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            #endif
            let busy = issue.busy || signingInSourceID == source.id
            ZStack {
                // Fixed footprint: progress replaces the button without moving the row.
                actionButton(source, issue).opacity(busy ? 0 : 1).disabled(busy)
                ProgressView().controlSize(.small).opacity(busy ? 1 : 0)
            }
        }
        .phoneHubBannerCard(tint: .orange)
    }

    private func actionButton(_ source: HubSourceWorkspace, _ issue: PhoneHubConnectionIssue) -> some View {
        Button(issue.action.title) {
            switch issue.action {
            case .retry: Task { await source.store.refresh() }
            case .reconnect: linkedDevices.reconnectNow(source.id)
            case .signIn, .review: onOpen(source, issue.action)
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .controlSize(.small)
        .disabled(issue.busy)
        .accessibilityLabel("\(issue.action.title) \(issue.name)")
        .accessibilityIdentifier("phoneHub.issue.action.\(issue.id.uuidString)")
    }
}

#if os(macOS)
@MainActor
struct MacLocalNetworkSettingsButton: View {
    static func isAvailable(for source: HubSourceWorkspace) -> Bool {
        source.offersLocalNetworkSettings && NativeApp.localNetworkPrivacySettingsURL != nil
    }

    var body: some View {
        Button("Open Privacy & Security…", action: NativeApp.openLocalNetworkPrivacySettings)
            .help("In Privacy & Security, select Local Network to see app permissions")
            .accessibilityIdentifier("phoneHub.localNetworkSettings")
    }
}
#endif

/// Pinned on the Agents home when nothing is configured: says what a
/// connection is for and adds one in a tap.
struct PhoneHubAddConnectionBanner: View {
    /// Nothing sits above it when there are no connections.
    var top: CGFloat = 8
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "link.badge.plus")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("No connections yet").font(.subheadline.weight(.semibold))
                Text("Add a term-llm Hub or agent to see your agents here.")
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength: 0)
            Button(action: onAdd) {
                // Phones keep the message readable beside a short label.
                Label(AppPlatform.isMac ? "Add Connection" : "Add", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("Add Connection")
            .accessibilityIdentifier("phoneHub.addConnection")
        }
        .accessibilityElement(children: .contain)
        .phoneHubBannerCard(tint: .accentColor)
        .phoneHubHomeBanner(top: top)
    }
}

extension View {
    /// One tinted card in the Agents home banner area.
    func phoneHubBannerCard(tint: Color) -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.3)))
    }

    /// Centred under the panel switcher, pinned above the scrolling content.
    func phoneHubHomeBanner(top: CGFloat = 0) -> some View {
        frame(maxWidth: 640)
            .padding(.horizontal, 16)
            .padding(.top, top)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            #if !os(macOS)
            // Pinned over the scrolling list, like the panel controls above it.
            .background(Color.platformGroupedBackground)
            #endif
    }
}

struct PhoneHubConnectionRowLabel: View {
    let name: String
    let style: PhoneHubConnectionStyle
    var showsChevron = false
    let subtitle: String
    let tone: PhoneHubConnectionStatus.Tone

    var body: some View {
        HStack(spacing: 12) {
            PhoneHubConnectionIcon(style: style)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(PhoneHubConnectionStatus(text: "", tone: tone).color).frame(width: 7, height: 7)
                    Text(subtitle)
                        .foregroundStyle(tone == .warning ? Color.orange : Color.secondary)
                        .lineLimit(1)
                }
                .font(.footnote)
            }
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
