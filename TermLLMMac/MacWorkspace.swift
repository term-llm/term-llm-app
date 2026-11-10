import AppKit
import Combine
import SwiftUI
import WebKit

/// The Mac client's one window. It plays the role a UIKit scene plays on
/// iPhone/iPad: a stable identity for notification routing, plus the
/// activation state that drives polling, presence and WebKit visibility.
///
/// Closing the window hides it instead of destroying it, so the native
/// navigation and the retained Chat document (and its unsent draft) survive
/// until the user quits. Multiple client windows stay disabled; see
/// NOTIFICATION-OWNERSHIP.md.
@MainActor
final class MacClientWindow: NSObject, ObservableObject {
    static let shared = MacClientWindow(defaults: HubFixture.defaults)

    nonisolated static let didEnterBackgroundNotification = Notification.Name("com.termllm.app.client.didEnterBackground")
    nonisolated static let willEnterForegroundNotification = Notification.Name("com.termllm.app.client.willEnterForeground")
    nonisolated static let didReceiveMemoryWarningNotification = Notification.Name("com.termllm.app.client.memoryWarning")
    nonisolated static let identifierKey = "mac.clientWindow.sceneIdentifier"

    /// Persistent like a UIKit scene session identifier; push routing hashes it.
    let sceneIdentifier: String
    private(set) weak var window: NSWindow?
    private var retained: RetainedWindowDelegate?
    /// Visible on screen: shown, not minimized, app not hidden.
    @Published private(set) var isVisible = true
    @Published private(set) var phase: ScenePhase = .active
    private var observers: [NSObjectProtocol] = []
    private var memoryPressure: DispatchSourceMemoryPressure?

    init(defaults: UserDefaults) {
        if let saved = defaults.string(forKey: Self.identifierKey), !saved.isEmpty {
            sceneIdentifier = saved
        } else {
            sceneIdentifier = UUID().uuidString
            defaults.set(sceneIdentifier, forKey: Self.identifierKey)
        }
        super.init()
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            NotificationCenter.default.post(name: MacClientWindow.didReceiveMemoryWarningNotification, object: nil)
        }
        source.resume()
        memoryPressure = source
    }

    /// The SwiftUI window hosting ContentView. Only that window is retained;
    /// sheets, Local Service and system panels keep ordinary semantics.
    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.tabbingMode = .disallowed
        // Destinations title themselves in the content. The title bar would
        // otherwise show whichever page last named the window.
        window.titleVisibility = .hidden
        retained = RetainedWindowDelegate(window: window) { [weak self] _ in self?.update() }
        update()
    }

    /// The hosting window's scene, or nil for any other window.
    func scene(for window: NSWindow?) -> MacClientWindow? {
        guard let window, window === self.window else { return nil }
        return self
    }

    var sceneSession: MacClientWindow { self }
    var isForegroundActive: Bool { phase == .active }
    var isAttachedToApp: Bool { window != nil }
    /// Key, or presenting the key sheet (SwiftUI sheets are attached windows).
    var hasKeyWindow: Bool {
        guard let window, let key = NSApp.keyWindow else { return false }
        return key === window || key.sheetParent === window
    }
    /// Menu commands act on the client only while it is key and unobstructed.
    var ownsKeyboard: Bool {
        guard let window else { return false }
        return NSApp.isActive && NSApp.keyWindow === window && window.attachedSheet == nil
    }

    var appState: NativeAppState {
        switch phase {
        case .active: .active
        case .background: .background
        default: .inactive
        }
    }

    /// Restores the same window (never a new one) and brings the app forward.
    func show() {
        if NSApp.isHidden { NSApp.unhide(nil) }
        retained?.show()
        NSApp.activate(ignoringOtherApps: true)
        update()
    }

    private func update() {
        let shown = window.map { $0.isVisible && !$0.isMiniaturized } ?? true
        let visible = shown && !NSApp.isHidden
        let next = MacLocalServiceBridge.effectiveScenePhase(NSApp.isActive ? .active : .inactive,
                                                             isMainWindowVisible: visible)
        let previous = phase
        if isVisible != visible { isVisible = visible }
        if phase != next { phase = next }
        // Only the app's own client window drives app-wide state.
        guard self === Self.shared else { return }
        MacLocalServiceBridge.shared.clientWindowChanged(isVisible: visible, phase: next)
        if previous != .background && next == .background {
            NotificationCenter.default.post(name: Self.didEnterBackgroundNotification, object: nil)
        } else if previous == .background && next != .background {
            NotificationCenter.default.post(name: Self.willEnterForegroundNotification, object: nil)
        }
    }
}

/// Retains the actual client window rather than recreating it on reopen. Only
/// the close decision is intercepted; every other delegate method SwiftUI's
/// own window delegate implements is advertised and forwarded to it.
@MainActor
final class RetainedWindowDelegate: NSObject, NSWindowDelegate {
    let window: NSWindow
    /// Read by the NSObject forwarding overrides, which AppKit calls on the main thread.
    nonisolated(unsafe) private weak var originalDelegate: NSWindowDelegate?
    private let onVisibilityChanged: (Bool) -> Void
    private var visibility: Bool

    var isVisible: Bool { window.isVisible && !window.isMiniaturized }

    init(window: NSWindow, onVisibilityChanged: @escaping (Bool) -> Void) {
        self.window = window
        self.originalDelegate = window.delegate
        self.onVisibilityChanged = onVisibilityChanged
        self.visibility = window.isVisible && !window.isMiniaturized
        super.init()
        window.delegate = self
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(updateVisibility), name: name, object: window)
        }
        onVisibilityChanged(visibility)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return originalDelegate?.windowShouldClose?(sender) ?? true }
        // Do not forward this one method: SwiftUI would tear down the scene
        // and the document with it. Resolve any attached sheet first.
        guard sender.attachedSheet == nil else { return false }
        sender.orderOut(nil)
        updateVisibility()
        return false
    }

    func show() {
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        updateVisibility()
    }

    @objc private func updateVisibility() {
        let current = isVisible
        guard current != visibility else { return }
        visibility = current
        onVisibilityChanged(current)
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        if originalDelegate?.responds(to: selector) == true { return originalDelegate }
        return super.forwardingTarget(for: selector)
    }
}

/// Resolves the actual hosting window, even on the setup screen, and makes it
/// the retained client window.
struct NativeSceneReader: NSViewRepresentable {
    /// The app's one client window; tests supply their own.
    var client = MacClientWindow.shared
    let ready: (NativeWindowScene) -> Void

    func makeNSView(context: Context) -> Reader {
        let view = Reader()
        view.client = client
        view.ready = ready
        return view
    }

    func updateNSView(_ view: Reader, context: Context) {
        view.ready = ready
        view.resolveScene()
    }

    final class Reader: NSView {
        var client = MacClientWindow.shared
        var ready: ((NativeWindowScene) -> Void)?
        private weak var resolved: NSWindow?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolveScene()
        }

        /// Called while SwiftUI renders (AppKit sends viewDidMoveToWindow when
        /// SwiftUI adds this view) and from updateNSView. Attaching publishes the
        /// window's visibility and phase, which SwiftUI does not allow during a
        /// view update, so it happens on the next main-queue turn.
        func resolveScene() {
            guard let window, window !== resolved, !window.isSheet else { return }
            resolved = window
            let client = client, callback = ready
            DispatchQueue.main.async {
                client.attach(window)
                callback?(client)
            }
        }
    }
}

// MARK: - Menu commands

/// Desktop commands for the one client window. ContentView supplies the
/// current policy and handler; menus reflect them and act only while the
/// client window is key without a sheet or alert in front of it.
@MainActor
final class DesktopCommandCenter: ObservableObject {
    static let shared = DesktopCommandCenter()

    @Published private(set) var policy: DesktopCommandPolicy?
    @Published private(set) var clientOwnsKeyboard = false
    private var handler: ((DesktopCommand) -> Void)?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshKeyboardOwner() }
            })
        }
    }

    func install(policy: DesktopCommandPolicy, handler: @escaping (DesktopCommand) -> Void) {
        self.handler = handler
        if self.policy != policy { self.policy = policy }
        refreshKeyboardOwner()
    }

    func allows(_ command: DesktopCommand) -> Bool {
        clientOwnsKeyboard && MacClientWindow.shared.ownsKeyboard && policy?.allows(command) == true
    }

    func perform(_ command: DesktopCommand) {
        // Recheck at execution, not only when the menu was validated.
        refreshKeyboardOwner()
        guard allows(command) else { return }
        handler?(command)
    }

    func title(for command: DesktopCommand) -> String {
        guard command == .refresh else { return command.title }
        switch policy?.refresh {
        case .agents: return "Refresh Agents"
        case .chat, .reopenChat: return "Reload Chat"
        case nil: return command.title
        }
    }

    private func refreshKeyboardOwner() {
        let owns = MacClientWindow.shared.ownsKeyboard
        if owns != clientOwnsKeyboard { clientOwnsKeyboard = owns }
    }
}

/// Publishes the scene's command policy without adding a responder layer:
/// AppKit menus reach SwiftUI through DesktopCommandCenter.
struct DesktopCommandHost<Content: View>: View {
    let policy: DesktopCommandPolicy
    let onCommand: (DesktopCommand) -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .onAppear { DesktopCommandCenter.shared.install(policy: policy, handler: onCommand) }
            .onChange(of: policy) { _, policy in
                DesktopCommandCenter.shared.install(policy: policy, handler: onCommand)
            }
    }
}

struct MacCommands: Commands {
    @ObservedObject var center: DesktopCommandCenter
    @ObservedObject var window: MacClientWindow
    let localService: MacLocalServiceBridge

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open term-llm") { window.show() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Local Service…") { localService.showLocalService() }
        }
        CommandGroup(replacing: .appSettings) {
            item(.settings)
        }
        CommandGroup(before: .toolbar) {
            item(.refresh)
            Divider()
            item(.zoomIn)
            item(.zoomOut)
            item(.resetZoom)
            Divider()
        }
        CommandMenu("Navigate") {
            ForEach(DesktopCommand.tabs, id: \.self) { command in
                Toggle(command.title, isOn: Binding(
                    get: { center.policy?.tab == command.tab },
                    set: { _ in center.perform(command) }))
                    .keyboardShortcut(command.keyEquivalent, modifiers: .command)
                    .disabled(!center.allows(command))
            }
            Divider()
            item(.back)
        }
    }

    private func item(_ command: DesktopCommand) -> some View {
        Button(center.title(for: command)) { center.perform(command) }
            .keyboardShortcut(command.keyEquivalent, modifiers: .command)
            .disabled(!center.allows(command))
    }
}

extension DesktopCommand {
    var keyEquivalent: KeyEquivalent { KeyEquivalent(Character(input)) }
}

// MARK: - Workspace views

/// App navigation belongs to the window, not to a destination's navigation
/// stack or the remote Chat document. The frontend keeps its own conversation
/// sidebar; a horizontal selector avoids placing an app sidebar beside it.
struct MacWorkspaceToolbar: ToolbarContent {
    let selection: AppTab
    let onSelect: (AppTab) -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Destination", selection: Binding(get: { selection }, set: onSelect)) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    Text(tab.title)
                        .tag(tab)
                        .accessibilityIdentifier("appTab." + tab.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 360)
            .help("Switch destination (⌘1–4)")
            .accessibilityIdentifier("workspace.destinations")
        }
    }
}

/// Hiding is not enough for WKWebView: while attached to a window WebKit still
/// treats the page as visible. Keep the hosting controller and its root
/// identity, but detach its view while another destination is selected.
struct WorkspaceRetainedDestination<Content: View>: NSViewControllerRepresentable {
    let isVisible: Bool
    /// Native destinations stay in the window while hidden; only Chat leaves it.
    var detachesWhenHidden = true
    @ViewBuilder var content: () -> Content

    func makeNSViewController(context: Context) -> WorkspaceDestinationController<Content> {
        let controller = WorkspaceDestinationController(rootView: content())
        controller.detachesWhenHidden = detachesWhenHidden
        return controller
    }

    func updateNSViewController(_ controller: WorkspaceDestinationController<Content>, context: Context) {
        controller.update(rootView: content(), isVisible: isVisible)
    }
}

final class WorkspaceDestinationController<Content: View>: NSViewController {
    let host: NSHostingController<Content>
    var detachesWhenHidden = true

    init(rootView: Content) {
        host = NSHostingController(rootView: rootView)
        host.sizingOptions = []
        // A Mac window has one toolbar and title, while every destination keeps
        // its own navigation stack. Bridged chrome from a hidden destination
        // stays on the window, so destinations draw their own (see
        // PushedPageHeader) and never touch the window's.
        host.sceneBridgingOptions = []
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(host)
        // Explicit sizing preserves the last viewport while detached.
        host.view.autoresizingMask = [.width, .height]
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if host.view.superview === view { host.view.frame = view.bounds }
    }

    func update(rootView: Content, isVisible visible: Bool) {
        _ = view
        view.isHidden = !visible
        host.rootView = rootView
        // Apply root updates even off screen: authorization revocation/source
        // replacement must dismantle a protected document without revisiting Chat.
        host.view.needsLayout = true
        host.view.layoutSubtreeIfNeeded()
        if !detachesWhenHidden {
            if host.view.superview == nil {
                host.view.frame = view.bounds
                view.addSubview(host.view)
            }
            if !visible { resignFocus() }
            return
        }
        if visible {
            guard host.view.superview == nil else { return }
            host.view.frame = view.bounds
            view.addSubview(host.view)
        } else if host.view.superview != nil {
            resignFocus()
            host.view.removeFromSuperview()
        }
    }

    /// Release keyboard focus before hiding, independently of remote JS.
    private func resignFocus() {
        if let window = view.window, let responder = window.firstResponder as? NSView,
           responder.isDescendant(of: host.view) {
            window.makeFirstResponder(nil)
        }
    }
}

/// The navigation bar of a page pushed inside a Mac destination: back,
/// title and actions above the content (the window toolbar is not per page).
struct PushedPageHeader<Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var actions: () -> Actions
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Back")
            .accessibilityLabel("Back")
            .accessibilityIdentifier("pushedPage.back")
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            actions()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minHeight: 52)
        .background(Color.platformSecondaryGroupedBackground)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pushedPage.header")
    }
}

/// A search field for a pushed page's header.
struct PushedPageSearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.platformBackground, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.25)))
        .frame(maxWidth: 260)
    }
}

/// A 44 pt control whose hit target stays at the icon.
struct WorkspaceSidebarButton: View {
    let isVisible: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Toggle Sidebar")
        .accessibilityLabel("Toggle sidebar")
        .accessibilityIdentifier("workspace.toggleSidebar")
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
    }
}

extension NSView {
    /// The client scene when this view is in the client window.
    @MainActor var nativeScene: NativeWindowScene? { MacClientWindow.shared.scene(for: window) }
}
