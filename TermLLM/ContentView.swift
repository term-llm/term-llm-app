import SwiftUI
import UserNotifications
import WebKit

struct ContentView: View {
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
    @State private var authenticatedCount = 0
    @State private var nativeLogin = NativeLogin()

    private var address: URL? { ServerAddress.parse(serverURL) }

    var body: some View {
        Group {
            if let address {
                browser(address)
            } else {
                setup
            }
        }
        .tint(.cyan)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingSettings) { settings }
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
            Text("Use an HTTPS URL for your server. Plain HTTP connections are not supported.")
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
        NavigationStack {
            ZStack {
                BrowserView(url: url, loading: $loading, canGoBack: $canGoBack,
                            loadError: $loadError, reloadCount: reloadCount, backCount: backCount,
                            authenticatedCount: authenticatedCount, onLoginRequired: { signIn(to: url) })
                    .ignoresSafeArea(edges: .bottom)
                if isSigningIn {
                    ProgressView("Signing in…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                if let loginError {
                    ContentUnavailableView("Sign-in needed", systemImage: "person.crop.circle.badge.exclamationmark",
                                           description: Text(loginError))
                        .padding()
                        .background(.regularMaterial)
                        .overlay(alignment: .bottom) {
                            Button("Sign in with passkey") { signIn(to: url) }
                                .buttonStyle(.borderedProminent)
                                .padding(.bottom, 40)
                        }
                }
                if let loadError {
                    ContentUnavailableView("Can't load server", systemImage: "wifi.exclamationmark",
                                           description: Text(loadError))
                        .padding()
                        .background(.regularMaterial)
                        .overlay(alignment: .bottom) {
                            Button("Retry") { self.loadError = nil; reloadCount += 1 }
                                .buttonStyle(.borderedProminent)
                                .padding(.bottom, 40)
                        }
                }
            }
            .navigationTitle("term-llm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { backCount += 1 } label: { Image(systemName: "chevron.left") }
                        .disabled(!canGoBack)
                        .accessibilityLabel("Back")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if loading { ProgressView() }
                    Button { reloadCount += 1 } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Reload")
                    Button {
                        draftURL = serverURL
                        showingSettings = true
                        refreshNotificationStatus()
                    } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
        }
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    addressField
                    Button("Save server", action: saveAddress)
                        .disabled(ServerAddress.parse(draftURL) == nil)
                    if let address {
                        Button("Sign in with passkey") {
                            showingSettings = false
                            signIn(to: address)
                        }
                        ShareLink("Open in Safari", item: address)
                    }
                }
                Section("Notifications") {
                    LabeledContent("Permission", value: notificationStatus)
                    Button("Enable notifications") {
                        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in
                            DispatchQueue.main.async { refreshNotificationStatus() }
                        }
                    }
                    Text("This enables iOS notification permission only. Completion alerts need native push support on the server; web push in Safari does not work inside this app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showingSettings = false }
                }
            }
        }
    }

    private func signIn(to url: URL) {
        guard !isSigningIn else { return }
        isSigningIn = true
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
