import SwiftUI
import UIKit
import UserNotifications
import WebKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("serverURL") private var serverURL = ""
    @AppStorage(AppControlsBar.hintAcknowledgedKey) private var appControlsHintAcknowledged = false
    @State private var draftURL = ""
    @State private var showingSettings = false
    @State private var loading = false
    @State private var canGoBack = false
    @State private var loadError: String?
    @State private var reloadCount = 0
    @State private var backCount = 0
    @State private var isSigningIn = false
    @State private var loginError: String?
    @State private var loginRequired = false
    @State private var showingControls = false
    @State private var showingMusic = false
    @State private var showingListen = false
    @State private var showingPlayer = false
    @State private var authenticatedCount = 0
    @State private var nativeLogin = NativeLogin()
    @StateObject private var deviceTools = DeviceToolsSettings.shared
    @StateObject private var voiceLaunches = VoiceLaunchCenter.shared
    @StateObject private var push = PushCenter.shared
    @State private var pushWindowID: String?
    @State private var pushActivity: NSUserActivity?
    @State private var voiceRequest: VoiceBrowserLaunch?
    @State private var voiceLaunchError: String?
    private let listen = Listen.shared

    private var address: URL? { ServerAddress.parse(serverURL) }
    private var hasPendingServerEdit: Bool {
        ServerAddress.parse(draftURL)?.absoluteString != serverURL
    }

    var body: some View {
        Group {
            if let address {
                browser(address)
            } else {
                setup
            }
        }
        .tint(.cyan)
        .background(NativeSceneReader { scene in
            let id = PushCenter.windowID(for: scene)
            push.registerWindow(id, scene: scene)
            pushWindowID = id
        })
        .sheet(isPresented: $showingSettings) { settings }
        .sheet(isPresented: $showingMusic) { MusicView(library: .shared) }
        .sheet(isPresented: $showingListen) { ListenView(listen: listen) }
        .sheet(isPresented: $showingPlayer) { ListenPlayerView(listen: listen) }
        .onChange(of: voiceLaunches.request, initial: true) { _, request in
            guard let request else { return }
            beginVoiceLaunch(request)
        }
        .onContinueUserActivity(PushCenter.navigationActivity) { activity in
            pushActivity = activity
            if let pushWindowID { push.claimNavigation(activity, windowID: pushWindowID) }
        }
        .onChange(of: pushWindowID) { _, id in
            if let id, let pushActivity { push.claimNavigation(pushActivity, windowID: id) }
            if let request = voiceLaunches.request { beginVoiceLaunch(request) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await push.refreshAuthorization() }
                if let request = voiceLaunches.request { beginVoiceLaunch(request) }
                push.routeManualToKeyScene()
            }
        }
        .alert(push.navigationIssue == nil ? "Voice shortcut" : "Notification", isPresented: Binding(
            get: {
                guard let pushWindowID, push.isKeyScene(pushWindowID) else { return false }
                return voiceLaunchError != nil || push.navigationIssue != nil
            },
            set: { if !$0 { voiceLaunchError = nil; push.navigationIssue = nil } }
        )) {
            Button("OK", role: .cancel) { voiceLaunchError = nil; push.navigationIssue = nil }
            Button("Settings") {
                voiceLaunchError = nil; push.navigationIssue = nil
                openSettings()
            }
        } message: {
            Text(push.navigationIssue ?? voiceLaunchError ?? "")
        }
    }

    private var setup: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.cyan)
                    Text("term-llm")
                        .font(.largeTitle.bold())
                    Text("Connect to your term-llm web server")
                        .foregroundStyle(.secondary)
                    addressField
                    Button("Connect", action: saveAddress)
                        .buttonStyle(.borderedProminent)
                        .disabled(ServerAddress.parse(draftURL) == nil)
                    Button("Try demo") {
                        draftURL = ServerAddress.demo
                        saveAddress()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("tryDemo")
                    Text("Explore with scripted replies—no server or sign-in needed. Demo chats reset on reload. Device tools stay off until you enable them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text("Use an HTTPS URL to connect to your own server.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(28)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
        }
        .onAppear { draftURL = serverURL }
    }

    private var addressField: some View {
        TextField("https://your-server.example", text: $draftURL)
            .textContentType(.URL)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.go)
            .onSubmit(saveAddress)
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("serverAddress")
    }

    /// The web page with the Listen mini player under it. The bar is native,
    /// so it (and playback) survives page loads; hiding it leaves playback on.
    private func browser(_ url: URL) -> some View {
        VStack(spacing: 0) {
            page(url)
            if listen.player.showsBar {
                MiniPlayerBar(listen: listen) { showingPlayer = true }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea(.keyboard)
        .animation(.snappy(duration: 0.25), value: listen.player.showsBar)
    }

    private func page(_ url: URL) -> some View {
        ZStack(alignment: .top) {
            BrowserView(url: url, loading: $loading, canGoBack: $canGoBack,
                        loadError: $loadError, loginRequired: $loginRequired,
                        reloadCount: reloadCount, backCount: backCount,
                        authenticatedCount: authenticatedCount,
                        scenePhase: scenePhase, isSigningIn: isSigningIn,
                        deviceTools: deviceTools.isEnabled(for: url) ? deviceTools.registry : nil,
                        onLoginRequired: { signIn(to: url) }, onRevealControls: revealControls,
                        voiceLaunch: voiceRequest, onVoiceLaunchFinished: finishVoiceLaunch,
                        push: push, pushNavigation: push.pendingNavigation, pushChangeCount: push.changeCount,
                        onPushNavigationHandled: push.navigationHandled,
                        onPushWindowReady: { pushWindowID = $0 })
                .ignoresSafeArea(edges: .bottom)
                .accessibilityAction(named: "App controls", revealControls)

            if let loadError {
                recoveryScreen("Can't load server", symbol: "wifi.exclamationmark", message: loadError) {
                    if canGoBack {
                        Button("Back") { backCount += 1 }
                            .buttonStyle(.bordered)
                    }
                    Button("Retry") { self.loadError = nil; reloadCount += 1 }
                        .buttonStyle(.borderedProminent)
                    Button("Settings", action: openSettings)
                        .buttonStyle(.bordered)
                }
            } else if loginRequired || loginError != nil {
                recoveryScreen("Sign-in needed", symbol: "person.crop.circle.badge.exclamationmark",
                               message: loginError ?? "Sign in to continue to this server.") {
                    Button("Sign in with passkey") { signIn(to: url) }
                        .buttonStyle(.borderedProminent)
                    Button("Settings", action: openSettings)
                        .buttonStyle(.bordered)
                }
            }

            if isSigningIn {
                ProgressView("Signing in…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black.opacity(0.25))
            }
        }
        .overlay(alignment: .top) {
            if appControlsAvailable {
                AppControlsBar(isExpanded: $showingControls,
                               hintAcknowledged: $appControlsHintAcknowledged,
                               canGoBack: canGoBack, onAction: handleAppControl)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }
        }
    }

    private var appControlsAvailable: Bool {
        loadError == nil && !loginRequired && loginError == nil && !isSigningIn
    }

    private func handleAppControl(_ action: AppControlAction) {
        switch action {
        case .back: backCount += 1
        case .reload: reloadCount += 1
        case .music: showingMusic = true
        case .listen:
            listen.player.showBar()
            showingListen = true
        case .settings: openSettings()
        }
    }

    private func recoveryScreen<Actions: View>(_ title: String, symbol: String, message: String,
                                                 @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 20) {
            ContentUnavailableView(title, systemImage: symbol, description: Text(message))
            VStack(spacing: 12, content: actions)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private func revealControls() {
        guard appControlsAvailable, !showingControls else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        appControlsHintAcknowledged = true
        showingControls = true
    }

    private func openSettings() {
        showingControls = false
        draftURL = serverURL
        showingSettings = true
        Task { await push.refreshAuthorization() }
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    addressField
                    if ServerAddress.parse(draftURL) == nil {
                        Text("Enter a valid server URL to continue.")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    } else if hasPendingServerEdit {
                        Text("Tap Done to connect to this server.")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    }
                    if let address {
                        Button("Sign in with passkey") {
                            showingSettings = false
                            signIn(to: address)
                        }
                        .disabled(hasPendingServerEdit)
                        ShareLink("Open in Safari", item: address)
                            .disabled(hasPendingServerEdit)
                    }
                }
                if let address {
                    VoiceShortcutSection(server: address) {
                        showingSettings = false
                        voiceLaunches.requestLaunch()
                    }
                    .disabled(hasPendingServerEdit)
                }
                notificationsSection
                deviceToolsSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        draftURL = serverURL
                        showingSettings = false
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: saveAddress)
                        .fontWeight(.semibold)
                        .disabled(ServerAddress.parse(draftURL) == nil)
                }
            }
        }
    }

    /// Per-server opt-in for sharing device tools with the web page (WebMCP).
    @ViewBuilder private var deviceToolsSection: some View {
        if let address {
            Section {
                Toggle(isOn: Binding(
                    get: { deviceTools.isEnabled(for: address) },
                    set: { deviceTools.setEnabled($0, for: address) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Share device tools with this server")
                        Text(address.host() ?? address.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(hasPendingServerEdit)
                .accessibilityIdentifier("deviceToolsToggle")
                if deviceTools.isEnabled(for: address) {
                    LabeledContent("Tools", value: deviceTools.registry.tools.map(\.name).joined(separator: ", "))
                }
            } header: {
                Text("Device tools")
            } footer: {
                Text("Lets the agent use tools on this \(UIDevice.current.model) while you chat here. They appear in term-llm's MCP servers list, where you can turn them off per conversation. Nothing listens on the network. Remembered per server.")
            }
        }
    }

    private func beginVoiceLaunch(_ id: UUID) {
        guard voiceRequest == nil, scenePhase == .active, let pushWindowID,
              voiceLaunches.claim(id, windowID: pushWindowID, isKeyScene: push.isKeyScene(pushWindowID)) else { return }
        do {
            guard let address else {
                throw VoiceLaunchFailure(message: "Connect to a server in Settings first.")
            }
            let destination = try VoiceShortcutSettings.shared.destination(for: address)
            showingSettings = false
            showingMusic = false
            showingListen = false
            showingPlayer = false
            voiceLaunchError = nil
            voiceRequest = VoiceBrowserLaunch(id: id, url: destination)
        } catch {
            voiceLaunchError = error.localizedDescription
            voiceLaunches.finish()
        }
    }

    private func finishVoiceLaunch(_ id: UUID, _ error: String?) {
        guard voiceRequest?.id == id else { return }
        voiceRequest = nil
        voiceLaunches.finish()
        voiceLaunchError = error
    }

    private func signIn(to url: URL) {
        guard !isSigningIn else { return }
        isSigningIn = true
        loginRequired = false
        loginError = nil
        nativeLogin.signIn(to: url) { result in
            isSigningIn = false
            switch result {
            case .success:
                loadError = nil
                authenticatedCount += 1
            case .failure(let error):
                loginError = error.localizedDescription
            }
        }
    }

    private func saveAddress() {
        guard let url = ServerAddress.parse(draftURL) else { return }
        let changed = serverURL != url.absoluteString
        if changed, let request = voiceRequest {
            finishVoiceLaunch(request.id, nil)
        }
        serverURL = url.absoluteString
        loadError = nil
        loginError = nil
        loginRequired = false
        showingSettings = false
    }

    /// One app-wide switch. Each server or hub agent enrolls itself when its
    /// page loads; its own settings can turn notifications off for it alone.
    private var notificationsSection: some View {
        Section {
            Toggle("Notifications", isOn: Binding(
                get: { push.enabled && push.authorization != .denied },
                set: { on in Task { await push.setEnabled(on) } }
            ))
            .disabled(push.authorization == .denied)
            .accessibilityIdentifier("notificationsToggle")
            if push.authorization == .denied {
                Button("Allow in iOS Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text(push.authorization == .denied
                 ? "Notifications are blocked for term-llm in iOS Settings."
                 : "This switch keeps a local opt-out; it does not change iOS permission. Cleanup of server enrollments retries when their authenticated pages reconnect. Offline or unopened nodes may retain remote subscriptions and in-flight alerts may still leave quiet cards.")
            if push.pendingCleanupCount > 0 {
                Text("\(push.pendingCleanupCount) server enrollment cleanup(s) pending. Open each enrolled node while signed in and online to retry.")
            }
            if let issue = push.storageIssue { Text(issue) }
            if let issue = push.navigationIssue { Text(issue) }
        }
    }
}

/// Resolve the actual containing scene even on the unconfigured/setup screen;
/// global shortcut/error handling must not sample an arbitrary current scene.
private struct NativeSceneReader: UIViewRepresentable {
    let ready: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> Reader {
        let view = Reader()
        view.isUserInteractionEnabled = false
        view.ready = ready
        return view
    }

    func updateUIView(_ view: Reader, context: Context) {
        view.ready = ready
        view.resolveScene()
    }

    final class Reader: UIView {
        var ready: ((UIWindowScene) -> Void)?
        private var lastIdentifier: String?

        override func didMoveToWindow() { super.didMoveToWindow(); resolveScene() }

        func resolveScene() {
            guard let scene = window?.windowScene, scene.session.persistentIdentifier != lastIdentifier else { return }
            lastIdentifier = scene.session.persistentIdentifier
            let callback = ready
            DispatchQueue.main.async { callback?(scene) }
        }
    }
}
