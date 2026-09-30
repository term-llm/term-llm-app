import SwiftUI
import UserNotifications
import WebKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("serverURL") private var serverURL = ""
    @State private var draftURL = ""
    @State private var showingSettings = false
    @State private var loading = false
    @State private var canGoBack = false
    @State private var loadError: String?
    @State private var reloadCount = 0
    @State private var backCount = 0
    @State private var notificationStatus = "Not enabled"
    @State private var isSigningIn = false
    @State private var loginError: String?
    @State private var loginRequired = false
    @State private var showingControls = false
    @State private var showingMusic = false
    @State private var authenticatedCount = 0
    @State private var nativeLogin = NativeLogin()
    @StateObject private var deviceTools = DeviceToolsSettings.shared

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
        .sheet(isPresented: $showingSettings) { settings }
        .sheet(isPresented: $showingMusic) { MusicView(library: .shared) }
    }

    private var setup: some View {
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
            Text("Use an HTTPS URL for your server. The simulator also supports HTTP on localhost for testing.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func browser(_ url: URL) -> some View {
        ZStack(alignment: .top) {
            BrowserView(url: url, loading: $loading, canGoBack: $canGoBack,
                        loadError: $loadError, loginRequired: $loginRequired,
                        reloadCount: reloadCount, backCount: backCount,
                        authenticatedCount: authenticatedCount,
                        scenePhase: scenePhase, isSigningIn: isSigningIn,
                        deviceTools: deviceTools.isEnabled(for: url) ? deviceTools.registry : nil,
                        onLoginRequired: { signIn(to: url) }, onRevealControls: revealControls)
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

            if showingControls && loadError == nil && !loginRequired && loginError == nil {
                controls
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: showingControls)
        .task(id: showingControls) {
            if showingControls {
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled { showingControls = false }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 18) {
            Button { backCount += 1; showingControls = false } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!canGoBack)
            .accessibilityLabel("Back")
            Button { reloadCount += 1; showingControls = false } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("Reload")
            Button { showingControls = false; showingMusic = true } label: {
                Image(systemName: "music.note")
            }
            .accessibilityLabel("Music")
            Button { showingControls = false; openSettings() } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
            Button { showingControls = false } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Hide app controls")
        }
        .font(.system(size: 18, weight: .medium))
        .padding(.horizontal, 20)
        .frame(height: 48)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 8)
        .accessibilityIdentifier("appControls")
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
        guard loadError == nil && !loginRequired && loginError == nil else { return }
        showingControls = true
    }

    private func openSettings() {
        showingControls = false
        draftURL = serverURL
        showingSettings = true
        refreshNotificationStatus()
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
                Section("Notifications") {
                    LabeledContent("Permission", value: notificationStatus)
                    Button("Enable notifications") {
                        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in
                            DispatchQueue.main.async { refreshNotificationStatus() }
                        }
                    }
                    Text("Permission only. Completion alerts need server-side push support.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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
        serverURL = url.absoluteString
        loadError = nil
        loginError = nil
        loginRequired = false
        showingSettings = false
    }

    private func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: notificationStatus = "Allowed"
                case .denied: notificationStatus = "Blocked in Settings"
                default: notificationStatus = "Not enabled"
                }
            }
        }
    }
}
