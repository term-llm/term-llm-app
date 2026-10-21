import SwiftUI

enum AppControlAction: CaseIterable, Hashable {
    case back, reload, music, listen, settings

    var title: String {
        switch self {
        case .back: "Back"
        case .reload: "Reload"
        case .music: "Music"
        case .listen: "Listen"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .back: "chevron.left"
        case .reload: "arrow.clockwise"
        case .music: "music.note"
        case .listen: "headphones"
        case .settings: "gearshape"
        }
    }
}

/// A first-use coachmark or the floating controls. Once learned and closed,
/// this contributes no visible chrome and intercepts no touches on the page.
struct AppControlsBar: View {
    static let hintAcknowledgedKey = "appControls.hintAcknowledged"

    @Binding var isExpanded: Bool
    @Binding var hintAcknowledged: Bool
    let canGoBack: Bool
    let onAction: (AppControlAction) -> Void

    var isVisible: Bool { isExpanded || !hintAcknowledged }

    var body: some View {
        Group {
            if isExpanded {
                HStack(spacing: 0) {
                    ForEach(AppControlAction.allCases, id: \.self) { action in
                        Button { activate(action) } label: {
                            Image(systemName: action.symbol)
                                .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .disabled(action == .back && !canGoBack)
                        .accessibilityLabel(action.title)
                        .accessibilityIdentifier("appControl.\(action.title.lowercased())")
                    }
                    Button { isExpanded = false } label: {
                        Image(systemName: "xmark")
                            .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Hide app controls")
                }
                .font(.system(size: 18, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .accessibilityIdentifier("appControls")
            } else if !hintAcknowledged {
                VStack(alignment: .leading, spacing: 6) {
                    Label("App controls", systemImage: "arrow.down")
                        .font(.subheadline.weight(.semibold))
                    Text("Pull down from the top of the page for Settings, Music, and Listen.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 24) {
                            tryItButton
                            dismissHintButton
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            tryItButton
                            dismissHintButton
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .accessibilityIdentifier("appControlsHint")
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 360)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
    }

    private var tryItButton: some View {
        Button("Try it", action: reveal)
            .font(.subheadline.weight(.semibold))
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityHint("Shows the floating app controls, including Settings.")
    }

    private var dismissHintButton: some View {
        Button("Got it", action: dismissHint)
            .font(.subheadline)
            .frame(minWidth: 44, minHeight: 44)
    }

    func reveal() {
        hintAcknowledged = true
        isExpanded = true
    }

    func dismissHint() {
        hintAcknowledged = true
    }

    func activate(_ action: AppControlAction) {
        hintAcknowledged = true
        isExpanded = false
        onAction(action)
    }
}
