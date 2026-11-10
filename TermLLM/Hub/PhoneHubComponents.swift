import SwiftUI

/// The selector has its own full-width centred row. Adding Sessions search
/// below it must never change its horizontal anchor.
struct PhoneHubPanelControls<Controls: View>: View {
    let selection: PhoneHubView.Panel
    let attention: String?
    let usesWorkspaceChrome: Bool
    let onSelect: @MainActor @Sendable (PhoneHubView.Panel) -> Void
    @ViewBuilder var sessionControls: () -> Controls

    private var controls: some View {
        VStack(alignment: AppPlatform.isMac ? .center : (usesWorkspaceChrome ? .leading : .center),
               spacing: AppPlatform.isMac ? 12 : 8) {
            PhoneHubPanelSelector(selection: selection, attention: attention, onSelect: onSelect)
                .equatable()
                .frame(maxWidth: usesWorkspaceChrome ? (AppPlatform.isMac ? 320 : 480) : .infinity)
                .frame(maxWidth: AppPlatform.isMac ? .infinity : nil)
            if selection == .sessions { sessionControls() }
        }
    }

    var body: some View {
        #if os(macOS)
        controls
            .frame(maxWidth: 900)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        #else
        controls
            .padding(.horizontal, 16)
            .padding(.vertical, usesWorkspaceChrome ? 12 : 6)
            .frame(maxWidth: usesWorkspaceChrome ? 900 : .infinity)
            .frame(maxWidth: .infinity)
            .background(Color.platformGroupedBackground)
        #endif
    }
}

/// Mac uses the system segmented picker: native keyboard behaviour and Liquid
/// Glass on current macOS. Phones keep the custom control with its count badge.
/// Polling invalidates the aggregate view frequently; equatable on the
/// selection and badge keeps unrelated updates from re-rendering it. The
/// callback only writes the owning view's panel state.
@MainActor struct PhoneHubPanelSelector: View, Equatable {
    let selection: PhoneHubView.Panel
    /// Attention badge text; nil hides the badge.
    let attention: String?
    let onSelect: @MainActor @Sendable (PhoneHubView.Panel) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.selection == rhs.selection && lhs.attention == rhs.attention }

    var body: some View {
        #if os(macOS)
        Picker("Agents view", selection: Binding(get: { selection }, set: { onSelect($0) })) {
            ForEach(PhoneHubView.Panel.allCases, id: \.self) { candidate in
                Text(candidate == .attention ? attention.map { "Attention · \($0)" } ?? "Attention" : candidate.rawValue)
                    .tag(candidate)
                    .accessibilityLabel(candidate.rawValue)
                    .accessibilityValue(candidate == .attention ? (attention.map { "\($0) need attention" } ?? "None") : "")
                    .accessibilityIdentifier("phoneHub." + (candidate == .nodes ? "nodes" : candidate.rawValue.lowercased()))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.regular)
        .accessibilityIdentifier("phoneHub.panels")
        #else
        HStack(spacing: 2) {
            ForEach(PhoneHubView.Panel.allCases, id: \.self) { candidate in
                segment(candidate)
            }
        }
        .padding(2)
        .background(Color.platformTertiaryFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("phoneHub.panels")
        #endif
    }

    private func segment(_ candidate: PhoneHubView.Panel) -> some View {
        let selected = candidate == selection
        return Button { onSelect(candidate) } label: {
            HStack(spacing: 5) {
                Text(candidate.rawValue)
                    .fontWeight(selected ? .semibold : .medium)
                    .foregroundStyle(.primary)
                if candidate == .attention, let attention {
                    Text(attention)
                        .font(.caption2.weight(.bold)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(.orange))
                }
            }
            .font(.subheadline)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, minHeight: AppPlatform.isMac ? 24 : 36)
            .padding(.horizontal, 4)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.platformBackground)
                        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(candidate.rawValue)
        .accessibilityValue(candidate == .attention ? (attention.map { "\($0) need attention" } ?? "None") : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("phoneHub." + (candidate == .nodes ? "nodes" : candidate.rawValue.lowercased()))
    }
}

/// Dedicated marker, never an AX identifier on a broad container.
struct PhoneHubFixtureBanner: View {
    var body: some View {
        if PhoneHubFixture.isEnabled {
            Text("DEMO FIXTURE · LOCAL")
                .font(.caption.bold()).frame(maxWidth: .infinity).padding(6)
                .background(.orange.opacity(0.25))
                .accessibilityIdentifier("phoneHub.fixtureBanner")
        }
    }
}

/// Shared with conversation rows: one column edge and a 12 pt text inset.
struct PhoneHubSessionSearchField: View {
    @Binding var text: String
    let onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if !AppPlatform.isMac {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary).accessibilityHidden(true)
            }
            TextField("Search sessions", text: $text)
                #if os(macOS)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                #endif
                .noAutocapitalization().autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(onSubmit)
                .focused($focused)
                .accessibilityIdentifier("phoneHub.sessionSearch")
            if !text.isEmpty {
                Button { text = ""; focused = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("phoneHub.sessionSearch.clear")
            }
        }
        .padding(.horizontal, AppPlatform.isMac ? 12 : 10)
        .padding(.vertical, 8)
        .frame(height: AppPlatform.isMac ? 38 : nil)
        .background(AppPlatform.isMac ? Color.primary.opacity(0.06) : Color.platformSecondaryGroupedBackground,
                    in: RoundedRectangle(cornerRadius: 10))
    }
}
