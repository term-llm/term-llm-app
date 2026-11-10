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
