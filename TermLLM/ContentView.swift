import SwiftUI
import UIKit
import UserNotifications
import WebKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("serverURL", store: HubFixture.defaults) private var serverURL = ""
    @AppStorage(AppControlsBar.hintAcknowledgedKey, store: HubFixture.defaults) private var appControlsHintAcknowledged = false
    @StateObject private var connections = HubConnectionStore(defaults: HubFixture.defaults)
    @StateObject private var aggregate = HubAggregateStore()
    @State private var draftURL = ""
    @State private var showingSettings = false
    @State private var voiceSettingsSourceID: UUID?
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
    @State private var showingHub = !HubFixture.isEnabled
    @State private var selectedTab: AppTab = .agents
    @State private var visitedTabs: Set<AppTab> = [.agents]
    @State private var playbackShelfState = MediaPlaybackShelf.State()
    @State private var retainedChat: ChatTabContext?
    @State private var pendingChat: ChatTabContext?
    @State private var workspaceChosen = false
    @State private var hubRole: HubServerRole = .unknown
    @State private var hubPresentation = UUID()
    @State private var hubDestination: HubBrowserDestination?
    @State private var hubBrowserRevoked = false
    @State private var importedServer: URL?
    @State private var pendingConnectionURL: URL?
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
    private var selectedWorkspace: HubSourceWorkspace? { connections.selectedID.flatMap { aggregate.source($0) } }
    private var isFixture: Bool { HubFixture.isEnabled || PhoneHubFixture.isEnabled }
    private var browserIsRevoked: Bool { hubBrowserRevoked || (!HubFixture.isEnabled && selectedWorkspace?.browserRevoked == true) }
    private var browserAuthenticationScript: String? {
        guard connections.selected?.kind == .directNode, let source = selectedWorkspace,
              let token = source.security?.bearer else { return nil }
        return HubConnectionSecurity.directBearerScript(token: token, server: source.connection.url)
    }
    private enum AppTab: String, CaseIterable {
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
    private var chatIsVisible: Bool { HubFixture.isEnabled ? !showingHub : selectedTab == .chat }
    private var phoneHome: some View {
        PhoneHubView(connections: connections, aggregate: aggregate, pendingConnectionURL: $pendingConnectionURL,
                     isVisible: selectedTab == .agents, onOpenChat: openPhoneChat, onSettings: openSettings)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if HubFixture.isEnabled {
                    if let address {
                        legacyBrowser(address)
                    } else {
                        setup
                    }
                } else {
                    appShell(address)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if isFixture {
                Text("DEMO FIXTURE · LOCAL")
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity)
                    .padding(6)
                    .background(.orange.opacity(0.25))
                    .accessibilityIdentifier(PhoneHubFixture.isEnabled ? "phoneHub.fixtureBanner" : "hub.fixtureBanner")
            }
        }
        .onChange(of: connections.connections, initial: true) { _, sources in
            guard !HubFixture.isEnabled else { return }
            aggregate.synchronize(sources.filter { $0.needsKindReview != true })
            if !isFixture { push.updateAttentionBadge(count: aggregate.attentionBadgeCount) }
        }
        .onChange(of: aggregate.attentionBadgeCount) { _, count in
            guard !isFixture else { return }
            push.updateAttentionBadge(count: count)
        }
        .onChange(of: connections.selectedID, initial: true) { _, id in
            HubCookieScopeRegistry.shared.selectedID = id
            guard !HubFixture.isEnabled else { return }
            if hubDestination?.sourceID != id {
                hubDestination = nil
                workspaceChosen = false
                retainedChat = nil
                pendingChat = nil
            }
            hubBrowserRevoked = false
            loadError = nil
            loginError = nil
            loginRequired = false
            hubRole = connections.selected?.kind == .hub ? .hub : .direct
            revealPendingPushIfOwned()
        }
        .onChange(of: loadError) { _, error in
            if error != nil { pendingChat = nil }
        }
        .onChange(of: selectedWorkspace?.browserIdentity) { _, _ in
            guard !HubFixture.isEnabled else { return }
            loadError = nil
            loginError = nil
            loginRequired = false
            canGoBack = false
            loading = false
            if selectedWorkspace?.browserRevoked == true {
                hubDestination = nil
                retainedChat = nil
                pendingChat = nil
                if let request = voiceRequest { finishVoiceLaunch(request.id, "Connection authorization changed. Sign in again before starting voice.") }
            }
        }
        .task(id: address) {
            guard HubFixture.isEnabled, let server = address else { return }
            let role = await HubServerRole.discover(server: server)
            guard !Task.isCancelled, address == server else { return }
            hubRole = role
            if role == .hub, !workspaceChosen, voiceRequest == nil, push.pendingNavigation == nil {
                showingHub = true
            }
        }
        .tint(.blue)
        .background(NativeSceneReader { scene in
            guard !isFixture else { return }
            let id = PushCenter.windowID(for: scene)
            push.registerWindow(id, scene: scene)
            pushWindowID = id
        })
        .sheet(isPresented: $showingSettings) {
            settings.safeAreaInset(edge: .bottom, spacing: 0) { PhoneHubFixtureBanner() }
        }
        .onOpenURL { link in
            guard !isFixture, let server = HubConnectionImport.server(from: link) else { return }
            importedServer = server
        }
        .alert("Add connection?", isPresented: Binding(
            get: { importedServer != nil }, set: { if !$0 { importedServer = nil } }
        )) {
            Button("Review connection") {
                pendingConnectionURL = importedServer
                importedServer = nil
                showingSettings = false
                showingHub = true
                selectTab(.agents)
            }
            Button("Cancel", role: .cancel) { importedServer = nil }
        } message: {
            Text("Only connect to a server you trust. Sign-in is separate.\n" + (importedServer?.absoluteString ?? ""))
        }
        .sheet(isPresented: $showingMusic) { MusicView(library: .shared).safeAreaInset(edge: .bottom, spacing: 0) { PhoneHubFixtureBanner() } }
        .sheet(isPresented: $showingListen) { ListenView(listen: listen).safeAreaInset(edge: .bottom, spacing: 0) { PhoneHubFixtureBanner() } }
        .sheet(isPresented: $showingPlayer) { ListenPlayerView(listen: listen).safeAreaInset(edge: .bottom, spacing: 0) { PhoneHubFixtureBanner() } }
        .onChange(of: push.pendingNavigation, initial: true) { _, _ in
            revealPendingPushIfOwned()
        }
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
            revealPendingPushIfOwned()
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
            if push.navigationIssue != nil {
                Button("Notification settings") {
                    voiceLaunchError = nil; push.navigationIssue = nil
                    openSettings()
                }
            } else if let id = connections.selectedID {
                Button("Voice settings") {
                    voiceLaunchError = nil
                    voiceSettingsSourceID = id
                    openSettings()
                }
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
                    Button("Connect", action: saveFixtureAddress)
                        .buttonStyle(.borderedProminent)
                        .disabled(ServerAddress.parse(draftURL) == nil)
                        .accessibilityIdentifier("serverConnect")
                    Button("Try demo") {
                        draftURL = ServerAddress.demo
                        saveFixtureAddress()
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
            .onSubmit(saveFixtureAddress)
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("serverAddress")
    }

    /// Native tabs own navigation appearance; each destination keeps a stable
    /// identity so switching tabs does not replace the retained browser document.
    @ViewBuilder private func appShell(_ url: URL?) -> some View {
        if #available(iOS 26.1, *) {
            nativeTabs(url)
                .tabViewBottomAccessory(isEnabled: playbackShelfState.visibleSource(for: shelfPlayback) != nil) {
                    playbackShelf(usesSystemBackground: true)
                }
        } else {
            nativeTabs(url)
        }
    }

    private func nativeTabs(_ url: URL?) -> some View {
        TabView(selection: $selectedTab) {
            tabContent {
                phoneHome
            }
            .tag(AppTab.agents)
            .tabItem { tabLabel(.agents) }

            tabContent {
                ZStack {
                    if let url, workspaceChosen {
                        page(url)
                    } else {
                        emptyChat
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .tag(AppTab.chat)
            .tabItem { tabLabel(.chat) }

            tabContent {
                if visitedTabs.contains(.music) {
                    MusicView(library: .shared, embedded: true, isActive: selectedTab == .music)
                }
            }
            .tag(AppTab.music)
            .tabItem { tabLabel(.music) }

            tabContent {
                if visitedTabs.contains(.podcasts) {
                    NavigationStack {
                        ListenView(listen: listen, embedded: true, isActive: selectedTab == .podcasts)
                    }
                }
            }
            .tag(AppTab.podcasts)
            .tabItem { tabLabel(.podcasts) }
        }
        .onChange(of: selectedTab) { _, tab in selectTab(tab) }
        .onChange(of: shelfPlayback, initial: true) { _, playback in
            playbackShelfState.update(playback)
        }
    }

    private func tabLabel(_ tab: AppTab) -> some View {
        Label(tab.title, systemImage: tab.symbol)
            .accessibilityIdentifier("appTab." + tab.rawValue)
    }

    @ViewBuilder private func tabContent<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if #available(iOS 26.1, *) {
            ZStack { content() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack { content() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .bottom, spacing: 0) { playbackShelf() }
        }
    }

    private var shelfPlayback: MediaPlaybackShelf.Playback {
        let music = MusicLibrary.shared.player
        return .init(podcastID: listen.player.currentID, podcastVisible: listen.player.showsBar,
                     podcastPlaying: listen.player.isPlaying, musicID: music.nowPlaying?.id,
                     musicPlaying: music.isPlaying)
    }

    private func playbackShelf(usesSystemBackground: Bool = false) -> some View {
        MediaPlaybackShelf(listen: listen, music: MusicLibrary.shared.player,
                           state: $playbackShelfState, usesSystemBackground: usesSystemBackground,
                           onOpenPodcastPlayer: { showingPlayer = true },
                           onOpenMusic: { selectTab(.music) })
    }

    private var emptyChat: some View {
        GeometryReader { geometry in
            ScrollView {
                ContentUnavailableView {
                    Label("Choose an agent", systemImage: "bubble.left.and.bubble.right")
                        .accessibilityIdentifier("chat.empty")
                } description: {
                    Text("Open a conversation from Agents. Your page and draft stay here.")
                } actions: {
                    Button("Browse agents") { selectTab(.agents) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("chat.chooseAgent")
                }
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    private func selectTab(_ tab: AppTab) {
        visitedTabs.insert(tab)
        selectedTab = tab
        showingControls = false
        if tab == .agents { showingHub = true }
        if tab == .chat { showingHub = false }
    }

    private func makeChatContext(for url: URL, source: HubSourceWorkspace? = nil) -> ChatTabContext? {
        guard let source = source ?? selectedWorkspace, source.isActive, !source.browserRevoked else { return nil }
        return ChatTabContext.resolve(connection: source.connection, browserIdentity: source.browserIdentity,
                                      url: url, agents: source.store.nodes)
    }

    private func browserCommitted(_ url: URL, sourceID: UUID, browserIdentity: UUID) {
        guard let source = aggregate.source(sourceID), source === selectedWorkspace,
              source.isActive, !source.browserRevoked, source.browserIdentity == browserIdentity else { return }
        // The first WebView load can briefly commit the source root before the
        // explicit agent destination. Do not relabel that request as another agent.
        if let pendingChat, pendingChat.agentID != nil, url == source.connection.url { return }
        retainedChat = makeChatContext(for: url, source: source)
        pendingChat = nil
    }

    /// Keep the original standalone Hub protocol fixture out of the production
    /// tab shell so its established authentication/administration tests remain valid.
    private func legacyBrowser(_ url: URL) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    workspaceChosen = true
                    hubPresentation = UUID()
                    showingHub = true
                    showingControls = false
                } label: { Label("Hub", systemImage: "square.grid.2x2") }
                .accessibilityIdentifier("hub.open")
                Spacer()
                Button("Chat") { workspaceChosen = true; showingHub = false }
                    .accessibilityIdentifier("hub.chat")
                Spacer()
                Button("Settings", systemImage: "gearshape", action: openSettings)
            }
            .buttonStyle(.borderless).padding(.horizontal).frame(minHeight: 48).background(.bar)
            ZStack {
                page(url)
                    .opacity(showingHub ? 0 : 1)
                    .allowsHitTesting(!showingHub)
                    .accessibilityHidden(showingHub)
                if showingHub {
                    HubView(server: url, onOpenChat: { destination in
                        loadError = nil
                        loginRequired = false
                        hubDestination = HubBrowserDestination(url: destination)
                        showingHub = false
                    }, onSettings: openSettings, requiresAuthentication: hubBrowserRevoked,
                            onAuthorizationRevoked: { [identity = hubPresentation] in
                                guard identity == hubPresentation else { return }
                                revokeHubBrowser()
                            }, onAuthenticated: { [identity = hubPresentation] in
                                guard identity == hubPresentation else { return }
                                restoreHubBrowser()
                            })
                    .id(url.absoluteString + hubPresentation.uuidString)
                }
            }
            if listen.player.showsBar {
                MiniPlayerBar(listen: listen) { showingPlayer = true }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea(.keyboard)
        .animation(.snappy(duration: 0.25), value: listen.player.showsBar)
    }

    private func page(_ url: URL) -> some View {
        let source = selectedWorkspace
        let browserIdentity = source?.browserIdentity
        return ZStack(alignment: .top) {
            if !HubFixture.isEnabled && !workspaceChosen {
                Color.clear
            } else if browserIsRevoked {
                recoveryScreen("Hub sign-in required", symbol: "lock.shield", message: "The previous private browser workspace was closed after authorization changed.") {
                    Button(HubFixture.isEnabled ? "Back to Hub" : "Choose an agent") {
                        showingHub = true
                        if !HubFixture.isEnabled { selectTab(.agents) }
                    }.buttonStyle(.borderedProminent)
                    if HubFixture.isEnabled { Button("Settings", action: openSettings).buttonStyle(.bordered) }
                }
            } else if !HubFixture.isEnabled && source?.browserReady != true {
                ProgressView("Preparing connection…")
            } else {
            BrowserView(url: url, loading: $loading, canGoBack: $canGoBack,
                        loadError: $loadError, loginRequired: $loginRequired,
                        reloadCount: reloadCount, backCount: backCount,
                        authenticatedCount: authenticatedCount,
                        scenePhase: chatIsVisible ? scenePhase : .inactive, isSigningIn: isSigningIn,
                        deviceTools: !isFixture && deviceTools.isEnabled(for: url) ? (source.map { deviceTools.registry(for: $0.connection) } ?? deviceTools.registry) : nil,
                        onLoginRequired: {
                            guard HubFixture.isEnabled || (source?.isActive == true && source?.browserIdentity == browserIdentity && connections.selectedID == source?.id) else { return }
                            loginRequired = true
                            if hubRole == .direct && chatIsVisible { signIn(to: url) }
                        }, onRevealControls: revealControls,
                        voiceLaunch: voiceRequest, onVoiceLaunchFinished: finishVoiceLaunch,
                        push: isFixture ? nil : push, pushNavigation: push.pendingNavigation, pushChangeCount: push.changeCount,
                        onPushNavigationHandled: push.navigationHandled,
                        onPushWindowReady: { pushWindowID = $0 }, nativeDestination: hubDestination,
                        isContentVisible: chatIsVisible,
                        websiteDataStore: HubFixture.isEnabled ? nil : selectedWorkspace?.security?.dataStore,
                        authenticationScript: browserAuthenticationScript,
                        connectionMount: HubFixture.isEnabled ? nil : source?.connection.url,
                        onAuthorizationRevoked: {
                            guard !HubFixture.isEnabled, let source, source.isActive,
                                  source.browserIdentity == browserIdentity else { return }
                            source.revokeAuthorization()
                        }, onDocumentCommitted: { destination in
                            guard !HubFixture.isEnabled, let source, let browserIdentity else { return }
                            browserCommitted(destination, sourceID: source.id, browserIdentity: browserIdentity)
                        })
                .id(HubFixture.isEnabled ? "legacy" : (selectedWorkspace?.id.uuidString ?? "none") + (selectedWorkspace?.browserIdentity.uuidString ?? ""))
                .ignoresSafeArea(edges: HubFixture.isEnabled ? .bottom : [])
                .accessibilityAction(named: "App controls", revealControls)
            }

            if let loadError {
                recoveryScreen("Can't load server", symbol: "wifi.exclamationmark", message: loadError) {
                    if canGoBack {
                        Button("Back") { backCount += 1 }
                            .buttonStyle(.bordered)
                    }
                    Button("Retry") { self.loadError = nil; reloadCount += 1 }
                        .buttonStyle(.borderedProminent)
                    if HubFixture.isEnabled {
                        Button("Settings", action: openSettings).buttonStyle(.bordered)
                    }
                }
            } else if loginRequired || loginError != nil {
                recoveryScreen("Sign-in needed", symbol: "person.crop.circle.badge.exclamationmark",
                               message: loginError ?? "Sign in to continue to this server.") {
                    Button("Sign in with passkey") { signIn(to: url) }
                        .buttonStyle(.borderedProminent)
                    if HubFixture.isEnabled {
                        Button("Settings", action: openSettings).buttonStyle(.bordered)
                    }
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
                               canGoBack: canGoBack, showsSettings: HubFixture.isEnabled,
                               showsMediaActions: HubFixture.isEnabled, onAction: handleAppControl)
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
        case .music:
            if HubFixture.isEnabled { showingMusic = true } else { selectTab(.music) }
        case .listen:
            listen.player.showBar()
            if HubFixture.isEnabled { showingListen = true } else { selectTab(.podcasts) }
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

    private func openPhoneChat(_ sourceID: UUID, _ destination: URL) {
        aggregate.synchronize(connections.connections.filter { $0.needsKindReview != true })
        guard let source = aggregate.source(sourceID), source.isActive, !source.browserRevoked else { return }
        Task { @MainActor in
            await source.prepareBrowserAuthentication()
            guard source.isActive, !source.browserRevoked,
                  aggregate.source(sourceID) === source else { return }
            // The selected URL mirror is committed before the destination. All
            // existing Listen/Push/Voice/device-tool paths observe this source.
            connections.select(sourceID)
            serverURL = source.connection.url.absoluteString
            hubRole = source.connection.kind == .hub ? .hub : .direct
            hubBrowserRevoked = false
            loadError = nil
            loginError = nil
            loginRequired = false
            hubDestination = HubBrowserDestination(url: destination, sourceID: sourceID)
            pendingChat = makeChatContext(for: destination, source: source)
            workspaceChosen = true
            showingHub = false
            selectTab(.chat)
        }
    }

    private func openSettings() {
        showingControls = false
        showingSettings = true
        Task { await push.refreshAuthorization() }
    }

    private var settings: some View {
        NavigationStack {
            Form {
                voiceAndDeviceSections
                notificationsSection
                if let issue = push.badgeIssue {
                    Section { Text(issue).font(.footnote).foregroundStyle(.secondary) }
                }
                Section {
                    Text("Manage connections and sign-in in Agents → Connections.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingSettings = false }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("settings.done")
                }
            }
        }
    }

    private var voiceSettingsSource: HubSourceWorkspace? {
        voiceSettingsSourceID.flatMap { aggregate.source($0) } ?? selectedWorkspace ?? aggregate.sources.first
    }

    /// App-level settings own these controls. Choosing their permission scope
    /// must not select a browser workspace or navigate the retained chat.
    @ViewBuilder private var voiceAndDeviceSections: some View {
        Section {
            if let source = voiceSettingsSource {
                Picker("Connection", selection: Binding(
                    get: { voiceSettingsSource?.id },
                    set: { voiceSettingsSourceID = $0 }
                )) {
                    ForEach(aggregate.sources) { source in
                        Text(source.connection.name).tag(Optional(source.id))
                    }
                }
                .accessibilityIdentifier("settings.toolsConnection")
                Text(source.connection.url.absoluteString)
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Add a connection in Agents → Connections to configure voice and device sharing.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Voice & device tools")
        } footer: {
            if voiceSettingsSource != nil {
                Text("Choose which server may use these features. Changing this setting does not switch your chat.")
            }
        }
        if let source = voiceSettingsSource {
            VoiceShortcutSection(server: source.connection.url) {
                connections.select(source.id)
                showingSettings = false
                voiceLaunches.requestLaunch()
            }
            deviceToolsSection(for: source.connection.url)
        }
    }

    /// Per-server opt-in for sharing device tools with the web page (WebMCP).
    private func deviceToolsSection(for address: URL) -> some View {
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

    private func revealPendingPushIfOwned() {
        guard !isFixture, push.pendingNavigation?.canPresent(in: pushWindowID, server: address) == true else { return }
        workspaceChosen = true
        showingSettings = false
        showingHub = false
        if let destination = push.pendingNavigation?.url { pendingChat = makeChatContext(for: destination) }
        selectTab(.chat)
    }

    private func beginVoiceLaunch(_ id: UUID) {
        guard voiceRequest == nil, scenePhase == .active, let pushWindowID,
              voiceLaunches.claim(id, windowID: pushWindowID, isKeyScene: push.isKeyScene(pushWindowID)) else { return }
        do {
            guard let address else {
                throw VoiceLaunchFailure(message: "Add a connection in Agents → Connections first.")
            }
            let destination = try VoiceShortcutSettings.shared.destination(for: address)
            workspaceChosen = true
            showingHub = false
            showingSettings = false
            showingMusic = false
            showingListen = false
            showingPlayer = false
            voiceLaunchError = nil
            voiceRequest = VoiceBrowserLaunch(id: id, url: destination)
            pendingChat = makeChatContext(for: destination)
            if !HubFixture.isEnabled { selectTab(.chat) }
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

    private func revokeHubBrowser() {
        // Destroy the protected WKWebView, not just its native dashboard cache.
        // Chat can no longer reveal a retained authenticated document after logout.
        hubBrowserRevoked = true
        hubDestination = nil
        canGoBack = false
        loading = false
        loadError = nil
        loginRequired = false
        loginError = nil
        if let request = voiceRequest { finishVoiceLaunch(request.id, "Hub authorization changed. Sign in again before starting voice.") }
    }

    private func restoreHubBrowser() {
        hubBrowserRevoked = false
        hubDestination = nil
        // All sign-in paths (including Settings/voice recovery) replace the
        // Hub owner, invalidating callbacks held by its previous client.
        hubPresentation = UUID()
        authenticatedCount += 1
    }

    private func signIn(to url: URL) {
        guard !isSigningIn else { return }
        isSigningIn = true
        loginRequired = false
        loginError = nil
        if !HubFixture.isEnabled, let source = selectedWorkspace, source.connection.url == url {
            Task { @MainActor in
                guard let epoch = await source.prepareAuthentication() else { isSigningIn = false; return }
                nativeLogin.cookieSink = source.nativeCookieSink(epoch: epoch)
                nativeLogin.signIn(to: url) { result in
                    isSigningIn = false
                    guard source.isActive, source.authEpoch == epoch else { return }
                    switch result {
                    case .success:
                        Task {
                            guard await source.authenticationSucceeded(epoch: epoch), connections.selectedID == source.id else { return }
                            loadError = nil
                            loginError = nil
                            loginRequired = false
                            hubBrowserRevoked = false
                            authenticatedCount += 1
                        }
                    case .failure(let error):
                        source.authenticationError = error.localizedDescription
                        if connections.selectedID == source.id { loginError = error.localizedDescription }
                    }
                }
            }
            return
        }
        guard HubFixture.isEnabled else { isSigningIn = false; return }
        nativeLogin.cookieSink = nil
        nativeLogin.signIn(to: url) { result in
            isSigningIn = false
            switch result {
            case .success:
                loadError = nil
                restoreHubBrowser()
            case .failure(let error):
                loginError = error.localizedDescription
            }
        }
    }

    // Only the legacy simulator fixture uses this standalone setup screen.
    // Real connection changes are owned exclusively by the phone Hub editor.
    private func saveFixtureAddress() {
        guard HubFixture.isEnabled, let url = ServerAddress.parse(draftURL),
              url == HubFixture.server else { return }
        let changed = serverURL != url.absoluteString
        if changed, let request = voiceRequest {
            finishVoiceLaunch(request.id, nil)
        }
        serverURL = url.absoluteString
        if changed {
            hubDestination = nil
            hubBrowserRevoked = false
            workspaceChosen = false
            hubRole = .unknown
            showingHub = false
        }
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
