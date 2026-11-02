import SwiftUI
import UIKit
import WebKit

@main
struct TermLLMApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Listen.connectToMusic(MusicLibrary.shared.player, listen: .shared)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

enum AppTab: String, CaseIterable {
    case agents, chat, music, podcasts
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .agents: "square.grid.2x2"
        case .chat: "bubble.left.and.bubble.right"
        case .music: "music.note"
        case .podcasts: "dot.radiowaves.left.and.right"
        }
    }
}

enum DesktopChatAppearance {
    static let defaultZoom = 1.25
    static func clamped(_ zoom: Double) -> Double {
        zoom.isFinite ? min(2, max(0.75, zoom)) : defaultZoom
    }
    static func adjusted(_ zoom: Double, by delta: Double) -> Double {
        clamped(clamped(zoom) + delta)
    }
}

enum DesktopCommand: String, CaseIterable {
    case agents, chat, music, podcasts, settings, refresh, back, zoomIn, zoomOut, resetZoom
    static let tabs: [Self] = [.agents, .chat, .music, .podcasts]
    static let zoom: [Self] = [.zoomIn, .zoomOut, .resetZoom]
    var tab: AppTab? { AppTab(rawValue: rawValue) }
    var title: String {
        switch self {
        case .settings: "Settings…"
        case .refresh: "Refresh Current View"
        case .back: "Back in Chat"
        case .zoomIn: "Larger Chat Text"
        case .zoomOut: "Smaller Chat Text"
        case .resetZoom: "Reset Chat Text to 125%"
        default: tab!.title
        }
    }
    var input: String {
        switch self {
        case .agents: "1"
        case .chat: "2"
        case .music: "3"
        case .podcasts: "4"
        case .settings: ","
        case .refresh: "r"
        case .back: "["
        case .zoomIn: "+"
        case .zoomOut: "-"
        case .resetZoom: "0"
        }
    }
    @MainActor func keyCommand() -> UIKeyCommand {
        let command = UIKeyCommand(title: title, action: #selector(DesktopCommandController.performDesktopCommand(_:)),
                                   input: input, modifierFlags: .command, propertyList: rawValue,
                                   discoverabilityTitle: title)
        // Do not preempt WebKit/native editing, focus, or unmodified text keys.
        command.wantsPriorityOverSystemBehavior = false
        return command
    }
}

struct DesktopCommandPolicy: Equatable {
    enum Refresh: Equatable { case agents, chat, reopenChat }
    var tab: AppTab
    var enabled: Bool
    var hasSources: Bool
    var chatAvailable: Bool
    var chatParked: Bool
    var canGoBack: Bool
    var canZoom: Bool = false

    var refresh: Refresh? {
        guard enabled else { return nil }
        switch tab {
        case .agents: return hasSources ? .agents : nil
        case .chat: return chatAvailable ? (chatParked ? .reopenChat : .chat) : nil
        // These destinations have no root-level refresh operation.
        case .music, .podcasts: return nil
        }
    }
    func allows(_ command: DesktopCommand) -> Bool {
        guard enabled else { return false }
        switch command {
        case .refresh: return refresh != nil
        case .back: return tab == .chat && chatAvailable && !chatParked && canGoBack
        case .zoomIn, .zoomOut, .resetZoom: return tab == .chat && chatAvailable && !chatParked && canZoom
        default: return true
        }
    }
}

/// A stable ancestor of the actual content (including WKWebView), not a hidden
/// sibling that needs to steal first responder or broadcast global notifications.
struct DesktopCommandHost<Content: View>: UIViewControllerRepresentable {
    let policy: DesktopCommandPolicy
    let onCommand: (DesktopCommand) -> Void
    @ViewBuilder var content: () -> Content

    func makeUIViewController(context: Context) -> DesktopCommandController {
        let controller = DesktopCommandController()
        let host = UIHostingController(rootView: content())
        controller.addChild(host)
        controller.view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: controller.view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor)
        ])
        host.didMove(toParent: controller)
        return controller
    }

    func updateUIViewController(_ controller: DesktopCommandController, context: Context) {
        // Updating a hosting root of the same type preserves SwiftUI/WebKit identity.
        (controller.children.first as? UIHostingController<Content>)?.rootView = content()
        let changed = controller.policy != policy
        controller.policy = policy
        controller.onCommand = onCommand
        if changed { UIMenuSystem.main.setNeedsRevalidate() }
    }
}

final class DesktopCommandController: UIViewController {
    var policy: DesktopCommandPolicy?
    var onCommand: ((DesktopCommand) -> Void)?

    override var keyCommands: [UIKeyCommand]? { DesktopCommand.allCases.map { $0.keyCommand() } }
    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Supply an initial keyboard target on native screens, but never displace
        // a WebKit/native text field that already owns the keyboard.
        func containsFirstResponder(_ view: UIView) -> Bool {
            view.isFirstResponder || view.subviews.contains(where: containsFirstResponder)
        }
        if let window = view.window, !containsFirstResponder(window) { becomeFirstResponder() }
    }

    private var ownsActiveContent: Bool {
        guard let window = viewIfLoaded?.window, window.isKeyWindow,
              window.windowScene?.activationState == .foregroundActive else { return false }
        // Sheets/alerts (including descendants' editors) own their own keyboard
        // interaction. Do not navigate or reload the obscured document behind them.
        func hasPresentation(_ controller: UIViewController) -> Bool {
            controller.presentedViewController != nil || controller.children.contains(where: hasPresentation)
        }
        return window.rootViewController.map { !hasPresentation($0) } ?? false
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(performDesktopCommand(_:)) {
            guard ownsActiveContent, let command = sender as? UICommand,
                  let value = command.propertyList as? String,
                  let intent = DesktopCommand(rawValue: value) else { return false }
            return policy?.allows(intent) == true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func validate(_ command: UICommand) {
        super.validate(command)
        guard let value = command.propertyList as? String, let intent = DesktopCommand(rawValue: value) else { return }
        if let tab = intent.tab { command.state = policy?.tab == tab ? .on : .off }
        if intent == .refresh {
            switch policy?.refresh {
            case .agents: command.title = "Refresh Agents"
            case .chat, .reopenChat: command.title = "Reload Chat"
            case nil: command.title = intent.title
            }
        }
    }

    @objc func performDesktopCommand(_ sender: UICommand) {
        // Recheck at execution, not only when the menu was built/validated.
        guard canPerformAction(#selector(performDesktopCommand(_:)), withSender: sender),
              let value = sender.propertyList as? String, let command = DesktopCommand(rawValue: value) else { return }
        onCommand?(command)
    }
}

/// A scene's shell is chosen by device, not size class or window width. In
/// particular, a narrow iPad never becomes the phone TabView (or reparents Chat).
enum WorkspacePlatform: Equatable {
    case phone, pad, mac

    init(idiom: UIUserInterfaceIdiom, isIOSAppOnMac: Bool) {
        self = isIOSAppOnMac ? .mac : (idiom == .pad ? .pad : .phone)
    }

    @MainActor static var current: Self {
        Self(idiom: UIDevice.current.userInterfaceIdiom, isIOSAppOnMac: ProcessInfo.processInfo.isiOSAppOnMac)
    }

    var usesWorkspaceChrome: Bool { self != .phone }
}

struct WorkspaceLayoutPolicy: Equatable {
    let platform: WorkspacePlatform
    let width: CGFloat
    var persistentSidebarHidden = false
    var overlayPresented = false

    var sidebarWidth: CGFloat {
        switch platform {
        case .phone: 0
        case .pad: 200
        case .mac: 220
        }
    }
    var supportsPersistentSidebar: Bool { platform.usesWorkspaceChrome && width >= 900 }
    var showsPersistentSidebar: Bool { supportsPersistentSidebar && !persistentSidebarHidden }
    var showsOverlaySidebar: Bool { platform.usesWorkspaceChrome && !supportsPersistentSidebar && overlayPresented }
    var showsSidebar: Bool { showsPersistentSidebar || showsOverlaySidebar }
    var contentInset: CGFloat { showsPersistentSidebar ? sidebarWidth : 0 }
    var showsSidebarToggle: Bool { platform.usesWorkspaceChrome && !showsPersistentSidebar }
}

/// One structural hierarchy at every workspace width. Only frame/visibility
/// values change: destinations are never moved between a split view and a tab
/// view, or between conditional branches. The shelf is shared outside scrolling
/// destinations. Native destinations own their headers; Chat has no native one.
struct WorkspaceShell<Agents: View, Chat: View, Music: View, Podcasts: View, Shelf: View>: View {
    let platform: WorkspacePlatform
    let selection: AppTab
    let visitedTabs: Set<AppTab>
    let chatAgentName: String?
    let onSelect: (AppTab) -> Void
    let onSettings: () -> Void
    @ViewBuilder var agents: ((() -> Void)?) -> Agents
    @ViewBuilder var chat: () -> Chat
    @ViewBuilder var music: ((() -> Void)?) -> Music
    @ViewBuilder var podcasts: ((() -> Void)?) -> Podcasts
    @ViewBuilder var shelf: () -> Shelf
    @State private var persistentSidebarHidden = false
    @State private var overlayPresented = false

    var body: some View {
        GeometryReader { geometry in
            let layout = WorkspaceLayoutPolicy(platform: platform, width: geometry.size.width,
                                                persistentSidebarHidden: persistentSidebarHidden,
                                                overlayPresented: overlayPresented)
            let toggle: (() -> Void)? = layout.showsSidebarToggle ? { toggleSidebar(layout) } : nil
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    // Chat's web header and composer remain completely uncovered.
                    // A 44 pt leading rail, not a second header or floating button,
                    // supplies native navigation when no sidebar is visible.
                    VStack(spacing: 0) {
                        sidebarToggle(isVisible: selection == .chat && layout.showsSidebarToggle) { toggleSidebar(layout) }
                        Spacer(minLength: 0)
                            .accessibilityHidden(true)
                    }
                    .frame(width: selection == .chat && layout.showsSidebarToggle ? 44 : 0)
                    .frame(maxHeight: .infinity)
                    .background(Color(.secondarySystemBackground))
                    .clipped()
                    .accessibilityElement(children: .contain)
                    .opacity(selection == .chat && layout.showsSidebarToggle ? 1 : 0)
                    .allowsHitTesting(selection == .chat && layout.showsSidebarToggle)
                    .accessibilityHidden(selection != .chat || !layout.showsSidebarToggle)

                    VStack(spacing: 0) {
                        ZStack {
                            agents(toggle)
                                .workspaceNativeDestination(isVisible: selection == .agents)
                            WorkspaceRetainedDestination(isVisible: selection == .chat) {
                                chat()
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            // Lazy first mount is the only conditional. Once
                            // visited, the native navigation/player trees remain.
                            if visitedTabs.contains(.music) {
                                music(toggle)
                                    .workspaceNativeDestination(isVisible: selection == .music)
                            }
                            if visitedTabs.contains(.podcasts) {
                                podcasts(toggle)
                                    .workspaceNativeDestination(isVisible: selection == .podcasts)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        shelf()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.leading, layout.contentInset)
                .accessibilityHidden(layout.showsOverlaySidebar)

                Color.black.opacity(layout.showsOverlaySidebar ? 0.18 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture { overlayPresented = false }
                    .allowsHitTesting(layout.showsOverlaySidebar)
                    .accessibilityHidden(true)

                sidebar(layout)
                    .frame(width: layout.sidebarWidth)
                    .frame(maxHeight: .infinity)
                    .background(Color(.secondarySystemBackground))
                    .overlay(alignment: .trailing) { Divider() }
                    .offset(x: layout.showsSidebar ? 0 : -layout.sidebarWidth)
                    .opacity(layout.showsSidebar ? 1 : 0)
                    .allowsHitTesting(layout.showsSidebar)
                    .accessibilityHidden(!layout.showsSidebar)
            }
            .clipped()
            .onChange(of: layout.supportsPersistentSidebar) { _, _ in
                // Rotation/window resizing cannot leave a stale overlay open.
                overlayPresented = false
            }
            .onKeyPress(.escape) {
                guard overlayPresented else { return .ignored }
                overlayPresented = false
                return .handled
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.shell")
    }

    private func toggleSidebar(_ layout: WorkspaceLayoutPolicy) {
        if layout.supportsPersistentSidebar {
            persistentSidebarHidden.toggle()
            overlayPresented = false
        } else {
            overlayPresented.toggle()
        }
    }

    private func sidebarToggle(isVisible: Bool = true, action: @escaping () -> Void) -> some View {
        WorkspaceSidebarButton(isVisible: isVisible, action: action)
            .frame(width: 44, height: 44)
    }

    private func sidebar(_ layout: WorkspaceLayoutPolicy) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("term-llm")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 18)
                Spacer(minLength: 0)
                sidebarToggle(isVisible: layout.showsSidebar) { toggleSidebar(layout) }
            }
            .frame(height: 52)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(AppTab.allCases, id: \.self) { tab in
                        Button {
                            onSelect(tab)
                            overlayPresented = false
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: tab.symbol).frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tab.title).font(.system(size: 15, weight: selection == tab ? .semibold : .regular))
                                    if tab == .chat, let chatAgentName, !chatAgentName.isEmpty {
                                        Text(chatAgentName).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .frame(minHeight: 44)
                            .background(selection == tab ? Color.primary.opacity(0.07) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("appTab." + tab.rawValue)
                        .accessibilityAddTraits(selection == tab ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
            Divider().padding(.horizontal, 16)
            Button {
                overlayPresented = false
                onSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .font(.system(size: 15))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)
            .accessibilityIdentifier("workspace.settings")
        }
    }
}

private extension View {
    func workspaceNativeDestination(isVisible: Bool) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityElement(children: .contain)
            .accessibilityHidden(!isVisible)
    }
}

/// Opacity/accessibility hiding is not enough for WKWebView: while attached to a
/// window WebKit still treats the page as visible. Keep the hosting controller
/// and its root identity, but detach its view just as a native inactive tab does.
/// This representable stays in the same ZStack slot through every shell change.
struct WorkspaceRetainedDestination<Content: View>: UIViewControllerRepresentable {
    let isVisible: Bool
    @ViewBuilder var content: () -> Content

    func makeUIViewController(context: Context) -> WorkspaceDestinationController<Content> {
        WorkspaceDestinationController(rootView: content())
    }

    func updateUIViewController(_ controller: WorkspaceDestinationController<Content>, context: Context) {
        controller.update(rootView: content(), isVisible: isVisible)
    }
}

final class WorkspaceDestinationController<Content: View>: UIViewController {
    let host: UIHostingController<Content>
    private var scrollPositions: [WorkspaceScrollPosition] = []
    private var restoresScrollOnLayout = false
    private var hostingIsAppeared = false

    override var shouldAutomaticallyForwardAppearanceMethods: Bool { false }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if host.view.superview === view { setHostingAppeared(true) }
    }

    override func viewWillDisappear(_ animated: Bool) {
        setHostingAppeared(false)
        super.viewWillDisappear(animated)
    }

    private func setHostingAppeared(_ appeared: Bool) {
        guard hostingIsAppeared != appeared else { return }
        hostingIsAppeared = appeared
        host.beginAppearanceTransition(appeared, animated: false)
        host.endAppearanceTransition()
    }

    init(rootView: Content) {
        host = UIHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        host.view.backgroundColor = .clear
        addChild(host)
        host.didMove(toParent: self)
        // Explicit sizing preserves the last viewport while detached. Removing
        // edge constraints must not propose an intrinsic/zero size to WebKit.
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard host.view.superview === view else { return }
        host.view.frame = view.bounds
        host.view.layoutIfNeeded()
        if restoresScrollOnLayout, view.bounds.width > 0, view.bounds.height > 0 {
            restoresScrollOnLayout = false
            for position in scrollPositions { position.restore(in: host.view) }
            scrollPositions = []
        }
    }

    func update(rootView: Content, isVisible visible: Bool) {
        loadViewIfNeeded()
        view.isHidden = !visible
        view.isUserInteractionEnabled = visible
        view.accessibilityElementsHidden = !visible
        if !visible, host.view.superview != nil {
            // Capture before updating/flushing the hosting root: a visibility
            // update may already make UIKit adjust a focused page's viewport.
            scrollPositions = WorkspaceScrollPosition.capture(in: host.view)
        }
        host.rootView = rootView
        // Apply root updates even off screen: authorization revocation/source
        // replacement must dismantle a protected document without revisiting Chat.
        // On hide this also delivers BrowserView's inactive state while attached.
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        if visible {
            guard host.view.superview == nil else { return }
            // Size before attaching, then restore after the final parent layout.
            // Neither operation replaces the hosting root or browser document.
            host.view.frame = view.bounds
            restoresScrollOnLayout = !scrollPositions.isEmpty
            view.addSubview(host.view)
            view.setNeedsLayout()
            if view.window != nil { setHostingAppeared(true) }
        } else if host.view.superview != nil {
            restoresScrollOnLayout = false
            setHostingAppeared(false)
            // Release native focus before detaching, independently of remote JS.
            host.view.endEditing(true)
            host.view.removeFromSuperview()
        }
    }
}

/// A native checkpoint across window detachment, never a page-navigation or JS
/// workaround. Navigation/reload invalidates it, and a revoked/replaced web view
/// is no longer a descendant of the retained root, so cannot receive old state.
@MainActor
private final class WorkspaceScrollPosition {
    private weak var webView: WKWebView?
    private let documentItem: WKBackForwardListItem?
    private let offset: CGPoint
    private var invalidated = false
    private var navigationObservation: NSKeyValueObservation?

    private init(webView: WKWebView) {
        self.webView = webView
        documentItem = webView.backForwardList.currentItem
        offset = webView.scrollView.contentOffset
        invalidated = webView.isLoading
        navigationObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] _, change in
            guard change.newValue == true else { return }
            MainActor.assumeIsolated { self?.invalidated = true }
        }
    }

    static func capture(in root: UIView) -> [WorkspaceScrollPosition] {
        if let webView = root as? WKWebView { return [WorkspaceScrollPosition(webView: webView)] }
        return root.subviews.flatMap { capture(in: $0) }
    }

    func restore(in root: UIView) {
        guard !invalidated, let webView, webView.isDescendant(of: root), !webView.isLoading,
              webView.backForwardList.currentItem === documentItem,
              !webView.scrollView.isTracking, !webView.scrollView.isDecelerating else { return }
        webView.scrollView.setContentOffset(offset, animated: false)
    }
}

/// A native 44pt control keeps its accessibility/hit frame at the icon instead
/// of inheriting the full-height navigation rail from SwiftUI's plain Button.
struct WorkspaceSidebarButton: UIViewRepresentable {
    let isVisible: Bool
    let action: () -> Void

    func makeCoordinator() -> Handler { Handler(action: action) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "sidebar.leading"), for: .normal)
        button.tintColor = .secondaryLabel
        button.accessibilityLabel = "Toggle sidebar"
        button.accessibilityIdentifier = "workspace.toggleSidebar"
        button.addTarget(context.coordinator, action: #selector(Handler.invoke), for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.action = action
        button.isHidden = !isVisible
        button.isAccessibilityElement = isVisible
    }

    final class Handler: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func invoke() { action() }
    }
}
