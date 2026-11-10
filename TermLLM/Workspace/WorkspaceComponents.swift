import SwiftUI

/// Quiet, native root chrome for the larger-screen workspace. Live Chat never
/// uses this: its existing web header remains the sole conversation header.
extension View {
    /// Settings subpages keep their navigation inside the bounded sheet. Mac
    /// retained destinations deliberately do not bridge window toolbars.
    @ViewBuilder func settingsPageTitle(_ title: String, isRoot: Bool = false) -> some View {
        #if os(macOS)
        navigationBarBackButtonHidden(true)
            .workspaceTopBar {
                if isRoot {
                    WorkspaceHeader(title: title) { EmptyView() }
                } else {
                    PushedPageHeader(title: title) { EmptyView() }
                }
            }
        #else
        navigationTitle(title).inlineNavigationTitle()
        #endif
    }

    /// Pins workspace chrome above scrolling content. iPhone/iPad scroll the
    /// content under it as a safe-area inset; Mac lists apply that inset
    /// twice, so the Mac stacks the bar above the list instead.
    @ViewBuilder func workspaceTopBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        #if os(macOS)
        VStack(spacing: 0) {
            bar()
            self
        }
        #else
        safeAreaInset(edge: .top, spacing: 0, content: bar)
        #endif
    }
}

struct WorkspaceHeader<Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    var onToggleSidebar: (() -> Void)? = nil
    @ViewBuilder var actions: () -> Actions
    @ScaledMetric(relativeTo: .headline) private var titleSize = 16

    var body: some View {
        HStack(spacing: 12) {
            if let onToggleSidebar {
                Button(action: onToggleSidebar) {
                    Image(systemName: "sidebar.left")
                        .frame(width: 32, height: 44)
                }
                .accessibilityLabel("Show sidebar")
                .accessibilityIdentifier("workspace.sidebar.toggle")
            }
            Text(title)
                .font(.system(size: titleSize, weight: .semibold))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("workspace.header.title")
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 8)
            actions()
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        .frame(minHeight: 52)
        .background(Color.platformSecondaryGroupedBackground)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.header")
    }
}

/// The root browser has no List editing/reordering semantics. A native SwiftUI
/// scroll stack avoids AppKit's implicit table gutters and separator drawing;
/// the editable agent history below continues to use List.
struct WorkspaceSessionList<Content: View>: View {
    var wide: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if os(macOS)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4, content: content)
                .buttonStyle(.plain)
                .frame(maxWidth: wide ? 900 : .infinity)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
        }
        #else
        List(content: content)
            .modifier(WorkspaceListWidth(enabled: wide))
        #endif
    }
}

/// Padding belongs inside the button label, so the entire row is clickable.
struct WorkspaceConversationLabel: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        #if os(macOS)
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
        #else
        content
        #endif
    }
}

/// Match Chat's quiet rounded hover/selection instead of ruled table rows.
struct WorkspaceConversationRow: ViewModifier {
    var isSelected = false
    @State private var hovered = false

    @ViewBuilder func body(content: Content) -> some View {
        #if os(macOS)
        content
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(isSelected ? 0.07 : (hovered ? 0.04 : 0))))
            .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .onHover { hovered = $0 }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        #else
        content
        #endif
    }
}

struct WorkspaceConversationList: ViewModifier {
    var wide: Bool

    @ViewBuilder func body(content: Content) -> some View {
        #if os(macOS)
        content
            .listStyle(.plain)
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .modifier(WorkspaceListWidth(enabled: wide))
        #else
        content.modifier(WorkspaceListWidth(enabled: wide))
        #endif
    }
}

/// Wide lists keep a comfortable reading measure without constraining their
/// navigation stacks or changing the phone's standard grouped-list margins.
struct WorkspaceListWidth: ViewModifier {
    var enabled: Bool
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        if enabled {
            #if os(macOS)
            // Constrain the List itself, before adding a pinned header. Scroll
            // margins on the surrounding VStack do not reach an AppKit List.
            content
                .frame(maxWidth: 900)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
            #else
            content
                .contentMargins(.horizontal, max(20, (width - 900) / 2), for: .scrollContent)
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { width = geometry.size.width }
                            .onChange(of: geometry.size.width) { _, value in width = value }
                    }
                }
            #endif
        } else {
            content
        }
    }
}
