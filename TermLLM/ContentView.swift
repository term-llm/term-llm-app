import SwiftUI
#if os(iOS)
import UIKit
#endif
import UserNotifications
import WebKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("serverURL", store: HubFixture.defaults) private var serverURL = ""
    @AppStorage("mac.chatZoom", store: HubFixture.defaults) private var macChatZoom = DesktopChatAppearance.defaultZoom
    @AppStorage(AppControlsBar.hintAcknowledgedKey, store: HubFixture.defaults) private var appControlsHintAcknowledged = false
    @StateObject private var connections = HubConnectionStore(defaults: HubFixture.defaults)
    @StateObject private var aggregate = HubAggregateStore()
    @StateObject private var macServices = MacLocalServiceBridge.shared
    @State private var localServiceTask: Task<Void, Never>?
    @State private var localAttachTask: Task<Void, Never>?
    @State private var draftURL = ""
    @State private var showingSettings = false
    @State private var voiceTarget = VoiceShortcutTarget.load(from: HubFixture.defaults)
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
    @StateObject private var linkedDevices = LinkedDevicesRuntime.shared
    @StateObject private var linkedDevicesPairing = LinkedDevicesPairingModel()
    @State private var pushWindowID: String?
    @State private var pushActivity: NSUserActivity?
    @State private var voiceRequest: VoiceBrowserLaunch?
    @State private var voiceLaunchError: String?
    /// The chat page's web view was closed to stop its web process.
    @State private var parkedBrowser: WebKitParkedPage?
    private let listen = Listen.shared

    // Closing the Mac window hides and retains it. Do not mistake that hidden
    // window for an attended/foreground client (or keep polling it). AppKit,
    // not SwiftUI's scenePhase, knows whether it is hidden or minimized.
    private var effectiveScenePhase: ScenePhase {
        #if os(macOS)
        macServices.windowPhase
        #else
        scenePhase
        #endif
    }

    private var address: URL? {
        ServerAddress.browserURL(serverURL, selectedConnection: connections.selected)
    }
    private var selectedWorkspace: HubSourceWorkspace? { connections.selectedID.flatMap { aggregate.source($0) } }
    private var isFixture: Bool { HubFixture.isEnabled || PhoneHubFixture.isEnabled }
    private var browserIsRevoked: Bool { hubBrowserRevoked || (!HubFixture.isEnabled && selectedWorkspace?.browserRevoked == true) }
    private var browserAuthenticationScript: String? {
        guard connections.selected?.kind == .directNode, let source = selectedWorkspace,
              let token = source.security?.bearer else { return nil }
        return HubConnectionSecurity.directBearerScript(token: token, server: source.connection.url)
    }
    private var desktopCommandPolicy: DesktopCommandPolicy {
        DesktopCommandPolicy(
            tab: selectedTab,
            enabled: effectiveScenePhase == .active && !HubFixture.isEnabled && !showingSettings &&
                !showingMusic && !showingListen && !showingPlayer && !linkedDevicesPairing.isPresented &&
                importedServer == nil && !isSigningIn,
            hasSources: !aggregate.sources.isEmpty,
            chatAvailable: chatIsVisible && workspaceChosen && address != nil && !browserIsRevoked &&
                selectedWorkspace?.browserReady == true && !loginRequired && loginError == nil,
            chatParked: parkedBrowser != nil,
            canGoBack: canGoBack,
            canZoom: AppPlatform.isMac && appControlsAvailable)
    }

    private func performDesktopCommand(_ command: DesktopCommand) {
        // Resolve context afresh; a retained but hidden chat is never a target.
        guard desktopCommandPolicy.allows(command) else { return }
        if let tab = command.tab {
            selectTab(tab)
            return
        }
        switch command {
        case .settings: openSettings()
        case .back: backCount += 1
        case .zoomIn: macChatZoom = DesktopChatAppearance.adjusted(macChatZoom, by: 0.25)
        case .zoomOut: macChatZoom = DesktopChatAppearance.adjusted(macChatZoom, by: -0.25)
        case .resetZoom: macChatZoom = DesktopChatAppearance.defaultZoom
        case .refresh:
            switch desktopCommandPolicy.refresh {
            case .agents:
                aggregate.refresh()
                aggregate.rerunSearch()
            case .chat:
                loadError = nil
                reloadCount += 1
            case .reopenChat: resumeParkedBrowser(automatically: false)
            case nil: break
            }
        default: break
        }
    }
    private var chatIsVisible: Bool { HubFixture.isEnabled ? !showingHub : selectedTab == .chat }
    private var phoneHome: some View {
        PhoneHubView(connections: connections, aggregate: aggregate, pendingConnectionURL: $pendingConnectionURL,
                     isVisible: selectedTab == .agents, onOpenChat: openPhoneChat, onSettings: openSettings)
    }

    @ViewBuilder var body: some View {
        #if os(macOS)
        // Menu commands act on this window through DesktopCommandCenter.
        DesktopCommandHost(policy: desktopCommandPolicy, onCommand: performDesktopCommand) {
            integratedShellContent
        }
        #else
        integratedShellContent
        #endif
    }

    private var integratedShellContent: some View {
        shellContent
        .environment(\.scenePhase, effectiveScenePhase)
        .task {
            if !isFixture { macServices.start() }
            // A background request can arrive before this view observes changes.
            if let id = macServices.request?.id, let request = macServices.takeRequest(id) {
                handleLocalServiceRequest(request)
            }
        }
        .alert("Local Service", isPresented: Binding(
            get: { macServices.error != nil && !showingSettings },
            set: { if !$0 { macServices.error = nil } })) {
                Button("OK") { macServices.error = nil }
            } message: { Text(macServices.error ?? "") }
        .onChange(of: macServices.request?.id) { _, id in
            guard let id, let request = macServices.takeRequest(id) else { return }
            handleLocalServiceRequest(request)
        }
    }

    private func handleLocalServiceRequest(_ request: MacLocalServiceBridge.ChatRequest) {
        if request.open { openManagedLocalChat(request) } else { attachManagedLocalService(request) }
    }

    private var localServiceAction: (() -> Void)? {
        guard macServices.isSupported else { return nil }
        return { macServices.showLocalService() }
    }

    private var shellLayout: some View {
        VStack(spacing: 0) {
            Group {
                if HubFixture.isEnabled {
                    if let address {
                        legacyBrowser(address)
                    } else {
                        setup
                    }
                } else {
                    #if os(macOS)
                    workspaceShell(address)
                    #else
                    if WorkspacePlatform.current.usesWorkspaceChrome {
                        workspaceShell(address)
                    } else {
                        appShell(address)
                    }
                    #endif
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
    }

    // Split the modifier chain to keep Swift 6's type checker bounded.
    private var synchronizedShell: some View {
        shellLayout
        .onChange(of: connections.connections, initial: true) { _, sources in
            guard !HubFixture.isEnabled else { return }
            aggregate.synchronize(sources.filter { $0.needsKindReview != true })
            linkedDevices.synchronize(sources)
            if !isFixture { push.updateAttentionBadge(count: aggregate.attentionBadgeCount) }
        }
        .onChange(of: aggregate.attentionBadgeCount) { _, count in
            guard !isFixture else { return }
            push.updateAttentionBadge(count: count)
        }
        .onChange(of: linkedDevices.statuses) { previous, statuses in
            for (id, status) in statuses where previous[id] != status {
                guard let source = aggregate.source(id) else { continue }
                switch status {
                case .revoked, .identityChanged:
                    source.revokeAuthorization()
                case .connected(_):
                    if let old = previous[id], case .connected(_) = old { continue }
                    Task { @MainActor in
                        if source.browserRevoked {
                            guard let epoch = await source.prepareLinkedDevicesAuthorizationRestore(),
                                  await linkedDevices.reinstallCapability(for: id),
                                  await source.completeLinkedDevicesAuthorizationRestore(epoch: epoch) else { return }
                        }
                        // Polling that waited for this connection on return starts now.
                        if !aggregate.isPollingSuspended && !source.store.isPolling {
                            source.store.resumePolling()
                        } else {
                            await source.store.refresh()
                        }
                    }
                default:
                    break
                }
            }
        }
        .onChange(of: connections.selectedID, initial: true) { _, id in
            HubCookieScopeRegistry.shared.selectedID = id
            guard !HubFixture.isEnabled else { return }
            if parkedBrowser?.sourceID != id { discardParkedBrowser() }
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
        .onChange(of: selectedWorkspace?.browserIdentity) { _, identity in
            guard !HubFixture.isEnabled else { return }
            if parkedBrowser?.browserIdentity != identity { discardParkedBrowser() }
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
    }

    private var shellContent: some View {
        synchronizedShell
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
            settingsPresentation.safeAreaInset(edge: .bottom, spacing: 0) { PhoneHubFixtureBanner() }
        }
        .sheet(isPresented: Binding(get: { linkedDevicesPairing.isPresented }, set: { if !$0 { linkedDevicesPairing.dismiss() } })) {
            LinkedDevicesPairingView(model: linkedDevicesPairing, catalog: connections, runtime: linkedDevices)
        }
        .onOpenURL { link in
            guard !isFixture else { return }
            if linkedDevicesPairing.handle(link) { return }
            guard let server = HubConnectionImport.server(from: link) else { return }
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
        .onChange(of: parkedBrowserShouldReopen, initial: true) { _, reopen in
            // Chat is on screen again: reopen a page stopped while off screen.
            if reopen { resumeParkedBrowser(automatically: true) }
        }
        .onChange(of: effectiveScenePhase) { _, phase in
            if phase == .background {
                aggregate.setPollingSuspended(true)
                linkedDevices.setForeground(false)
            }
            if phase == .active {
                // Reconnect first. A linked source that has to reconnect resumes
                // polling once connected (see the statuses handler) instead of
                // failing its first poll.
                linkedDevices.setForeground(true)
                aggregate.setPollingSuspended(false, deferring: waitsForLinkedConnection)
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
            set: { if !$0 { voiceLaunchError = nil; push.dismissNavigationIssue() } }
        )) {
            if push.navigationIssue != nil {
                // Capture the page now: dismissal may clear it before the action runs.
                if let unrouted = push.unroutedNavigation, let pushWindowID {
                    Button("Open Here") {
                        voiceLaunchError = nil
                        push.openHere(unrouted, windowID: pushWindowID)
                    }
                    Button("Cancel", role: .cancel) { voiceLaunchError = nil; push.dismissNavigationIssue() }
                } else {
                    Button("OK", role: .cancel) { voiceLaunchError = nil; push.dismissNavigationIssue() }
                }
            } else {
                Button("OK", role: .cancel) { voiceLaunchError = nil }
                Button("Voice settings") {
                    voiceLaunchError = nil
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
            .urlTextEntry()
            .autocorrectionDisabled()
            .submitLabel(.go)
            .onSubmit(saveFixtureAddress)
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("serverAddress")
    }

    private func workspaceShell(_ url: URL?) -> some View {
        WorkspaceShell(platform: .current, selection: selectedTab, visitedTabs: visitedTabs,
                       chatAgentName: retainedChat?.agentName, onSelect: selectTab, onSettings: openSettings,
                       onLocalService: localServiceAction) { toggle in
            PhoneHubView(connections: connections, aggregate: aggregate, pendingConnectionURL: $pendingConnectionURL,
                         isVisible: selectedTab == .agents, onOpenChat: openPhoneChat, onSettings: openSettings,
                         usesWorkspaceChrome: true, onToggleSidebar: toggle)
        } chat: {
            ZStack {
                if let url, workspaceChosen {
                    page(url)
                } else {
                    emptyChat
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } music: { toggle in
            MusicView(library: .shared, embedded: true, isActive: selectedTab == .music,
                      usesWorkspaceChrome: true, onToggleSidebar: toggle)
        } podcasts: { toggle in
            NavigationStack {
                ListenView(listen: listen, embedded: true, isActive: selectedTab == .podcasts,
                           usesWorkspaceChrome: true, onToggleSidebar: toggle)
            }
        } shelf: {
            playbackShelf()
        }
        #if os(macOS)
        .toolbar {
            MacWorkspaceToolbar(selection: selectedTab, onSelect: selectTab)
        }
        #endif
        .onChange(of: shelfPlayback, initial: true) { _, playback in
            playbackShelfState.update(playback)
        }
    }

    #if os(iOS)
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
    #endif

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
        .background(Color.platformGroupedBackground)
    }

    private func selectTab(_ tab: AppTab) {
        visitedTabs.insert(tab)
        selectedTab = tab
        showingControls = false
        if tab == .agents { showingHub = true }
        if tab == .chat { showingHub = false }
        // Agents is the only screen that shows what the sources poll for.
        aggregate.setAgentsVisible(tab == .agents, deferring: waitsForLinkedConnection)
    }

    /// A linked device that is reconnecting starts polling once connected.
    private func waitsForLinkedConnection(_ source: HubSourceWorkspace) -> Bool {
        source.connection.isLinkedDevices && !linkedDevices.status(for: source.id).isConnected
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
        let isLinkedDevices = source?.connection.isLinkedDevices == true
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
            } else if let parked = parkedBrowser, parked.sourceID == source?.id, parked.browserIdentity == browserIdentity {
                parkedBrowserScreen(parked)
            } else {
            BrowserView(url: url, loading: $loading, canGoBack: $canGoBack,
                        loadError: $loadError, loginRequired: $loginRequired,
                        reloadCount: reloadCount, backCount: backCount,
                        authenticatedCount: authenticatedCount,
                        scenePhase: chatIsVisible ? effectiveScenePhase : .inactive,
                        textScale: AppPlatform.isMac ? DesktopChatAppearance.clamped(macChatZoom) : 1,
                        isSigningIn: isSigningIn,
                        deviceTools: !isFixture && !isLinkedDevices && deviceTools.isEnabled ? (source.map { deviceTools.registry(for: $0.connection) } ?? deviceTools.registry) : nil,
                        onLoginRequired: {
                            guard HubFixture.isEnabled || (source?.isActive == true && source?.browserIdentity == browserIdentity && connections.selectedID == source?.id) else { return }
                            if let source, source.connection.isLinkedDevices {
                                loadError = "This route is not available for a linked device."
                                return
                            }
                            loginRequired = true
                            if hubRole == .direct && chatIsVisible { signIn(to: url) }
                        }, onRevealControls: revealControls,
                        voiceLaunch: isLinkedDevices ? nil : voiceRequest, onVoiceLaunchFinished: finishVoiceLaunch,
                        push: isFixture || isLinkedDevices ? nil : push, pushNavigation: isLinkedDevices ? nil : push.pendingNavigation, pushChangeCount: push.changeCount,
                        onPushNavigationHandled: push.navigationHandled,
                        onPushWindowReady: { pushWindowID = $0 }, nativeDestination: hubDestination,
                        isContentVisible: chatIsVisible && macServices.isMainWindowVisible,
                        websiteDataStore: HubFixture.isEnabled ? nil : selectedWorkspace?.security?.dataStore,
                        authenticationScript: browserAuthenticationScript,
                        connectionMount: HubFixture.isEnabled ? nil : source?.connection.url,
                        allowsMediaCapture: true,
                        isLinkedDevices: isLinkedDevices,
                        onAuthorizationRevoked: {
                            guard !HubFixture.isEnabled, let source, source.isActive,
                                  source.browserIdentity == browserIdentity else { return }
                            if source.connection.isLinkedDevices { LinkedDevicesRuntime.shared.markRevoked(source.id) }
                            source.revokeAuthorization()
                        }, onDocumentCommitted: { destination in
                            guard !HubFixture.isEnabled, let source, let browserIdentity else { return }
                            browserCommitted(destination, sourceID: source.id, browserIdentity: browserIdentity)
                        }, onMediaCaptureChange: { capturing in
                            // A Live call keeps a linked device connected while the phone is locked.
                            guard let source, source.connection.isLinkedDevices else { return }
                            linkedDevices.setMediaCaptureActive(capturing, for: source.id)
                        }, health: HubFixture.isEnabled ? nil : WebKitHealthMonitor.shared,
                        onHealthTeardown: { reason, detail, restoreURL in
                            guard let source, let browserIdentity, source.isActive,
                                  source.browserIdentity == browserIdentity else { return }
                            parkBrowser(WebKitParkedPage(reason: reason, detail: detail, restoreURL: restoreURL,
                                                         sourceID: source.id, browserIdentity: browserIdentity,
                                                         destinationID: hubDestination?.id))
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
            // Desktop Back/Reload live in native menus and keyboard commands;
            // do not teach touch-only pull-down gestures or obscure web chrome.
            if appControlsAvailable && !AppPlatform.isMac {
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
        loadError == nil && !loginRequired && loginError == nil && !isSigningIn && parkedBrowser == nil
    }

    /// Off-screen stops reopen without asking once Chat is on screen again.
    private var parkedBrowserShouldReopen: Bool {
        parkedBrowser?.reason.resumesAutomatically == true && chatIsVisible && effectiveScenePhase == .active
    }

    /// Closing the web view ends its page process; the document is reopened
    /// at the page's last route rather than kept alive.
    private func parkBrowser(_ page: WebKitParkedPage) {
        if let request = voiceRequest {
            finishVoiceLaunch(request.id, "The chat page was stopped (\(page.reason.title.lowercased())). Run the shortcut again.")
        }
        parkedBrowser = page
        loading = false
        canGoBack = false
        showingControls = false
        WebKitHealthMonitor.shared.noteParked(page)
    }

    private func resumeParkedBrowser(automatically: Bool) {
        guard let parked = parkedBrowser else { return }
        parkedBrowser = nil
        // A newer destination (another chat, a notification) wins over the old route.
        if let restore = parked.restoreURL, hubDestination?.id == parked.destinationID,
           let source = selectedWorkspace, source.id == parked.sourceID,
           HubNavigation.isWithinMount(restore, server: source.connection.url) {
            hubDestination = HubBrowserDestination(url: restore, sourceID: source.id)
        }
        loadError = nil
        WebKitHealthMonitor.shared.noteResumed(parked, automatically: automatically)
    }

    /// The connection or its authorization changed: the stopped page will
    /// not come back, a different one opens instead.
    private func discardParkedBrowser() {
        guard let parked = parkedBrowser else { return }
        parkedBrowser = nil
        WebKitHealthMonitor.shared.noteDiscarded(parked)
    }

    @ViewBuilder private func parkedBrowserScreen(_ parked: WebKitParkedPage) -> some View {
        if parked.reason.resumesAutomatically {
            // Reopens as soon as Chat is on screen (see parkedBrowserShouldReopen).
            ProgressView("Reopening chat…")
        } else {
            recoveryScreen(parked.reason.title, symbol: parked.reason == .manual ? "pause.circle" : "exclamationmark.octagon",
                           message: parked.detail + " Reloading starts a new web process.") {
                Button("Reload page") { resumeParkedBrowser(automatically: false) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("chat.reloadParked")
            }
        }
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
        guard !AppPlatform.isMac, appControlsAvailable, !showingControls else { return }
        NativeDevice.lightImpact()
        appControlsHintAcknowledged = true
        showingControls = true
    }

    /// A signed-out or not-yet-ready connection cannot open the page directly;
    /// land on Agents with it selected so its sign-in is one tap away.
    private func openPushOnConnection(_ sourceID: UUID, _ destination: URL) {
        aggregate.synchronize(connections.connections.filter { $0.needsKindReview != true })
        if let source = aggregate.source(sourceID), source.isActive, !source.browserRevoked {
            openPhoneChat(sourceID, destination)
            return
        }
        connections.select(sourceID)
        showingSettings = false
        selectTab(.agents)
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
            resumeParkedBrowser(automatically: false)
            selectTab(.chat)
        }
    }

    /// Keeps a running, verified local service in the app's connections as
    /// This Mac, so nobody has to type a loopback address. Never navigates or
    /// alerts, and leaves an already signed-in This Mac (and its open chat) alone.
    private func attachManagedLocalService(_ request: MacLocalServiceBridge.ChatRequest) {
        #if os(macOS)
        localAttachTask?.cancel()
        localAttachTask = Task { @MainActor in
            guard let connection = try? connections.attachManagedLocalService(address: request.baseURL.absoluteString)
            else { return }
            aggregate.synchronize(connections.connections.filter { $0.needsKindReview != true })
            guard !Task.isCancelled, let source = aggregate.source(connection.id), source.isActive else { return }
            if source.security?.bearer == request.token, !source.store.unauthorized { return }
            await source.signInWithBearer(request.token)
        }
        #endif
    }

    private func openManagedLocalChat(_ request: MacLocalServiceBridge.ChatRequest) {
        #if os(macOS)
        localAttachTask?.cancel()
        localServiceTask?.cancel()
        localServiceTask = Task { @MainActor in
            do {
                let connection = try connections.saveManagedLocalService(address: request.baseURL.absoluteString)
                aggregate.synchronize(connections.connections.filter { $0.needsKindReview != true })
                guard let source = aggregate.source(connection.id) else { return }
                // Use the same isolated credential store, auth epochs and WebKit
                // document lifecycle as any remote Direct Node. Never share jars.
                await source.signInWithBearer(request.token)
                guard !Task.isCancelled, source.isActive, aggregate.source(connection.id) === source else { return }
                guard source.authenticationError == nil, source.browserReady, !source.browserRevoked else {
                    macServices.error = "Could not authenticate the local service. Check Local Service diagnostics and try again."
                    return
                }
                showingSettings = false
                openPhoneChat(connection.id, connection.url)
            } catch {
                guard !Task.isCancelled else { return }
                macServices.error = "Could not add the local service. Check the saved connections and Local Service diagnostics."
            }
        }
        #endif
    }

    private func openSettings() {
        showingControls = false
        showingSettings = true
        Task { await push.refreshAuthorization() }
    }

    @ViewBuilder private var settingsPresentation: some View {
        #if os(macOS)
        MacSettingsPresentation(onClose: { showingSettings = false }) {
            settings
        }
        #else
        settings
        #endif
    }

    private var settings: some View {
        NavigationStack {
            Form {
                if !HubFixture.isEnabled {
                    connectionsSection
                }
                if !aggregate.sources.isEmpty {
                    voiceShortcutSection
                    deviceToolsSection
                }
                if AppPlatform.isMac {
                    desktopChatAppearanceSection
                }
                if macServices.isSupported {
                    Section {
                        Button("Local Service…", systemImage: "desktopcomputer") {
                            macServices.showLocalService()
                        }
                        .accessibilityIdentifier("settings.localService")
                        Text("Optionally run term-llm on this Mac. Remote connections work without a local service.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let error = macServices.error {
                            Text(error).font(.footnote).foregroundStyle(.red)
                        }
                    } header: { Text("This Mac") }
                }
                notificationsSection
                if let issue = push.badgeIssue {
                    Section { Text(issue).font(.footnote).foregroundStyle(.secondary) }
                }
                if !HubFixture.isEnabled {
                    Section {
                        NavigationLink {
                            WebKitHealthView(monitor: .shared, parked: parkedBrowser,
                                             onReload: { resumeParkedBrowser(automatically: false) })
                        } label: {
                            WebKitHealthSettingsRow(monitor: .shared)
                        }
                        .accessibilityIdentifier("settings.webKitHealth")
                    } header: {
                        Text("Diagnostics")
                    }
                }
            }
            .settingsPageTitle("Settings", isRoot: true)
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingSettings = false }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("settings.done")
                }
            }
            #endif
        }
    }

    private var desktopChatAppearanceSection: some View {
        Section {
            HStack(spacing: 12) {
                Text("Chat zoom")
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Button {
                        macChatZoom = DesktopChatAppearance.adjusted(macChatZoom, by: -0.25)
                    } label: {
                        Image(systemName: "minus")
                    }
                    .accessibilityLabel("Zoom out chat")
                    .accessibilityIdentifier("settings.chatZoom.decrease")
                    .disabled(DesktopChatAppearance.clamped(macChatZoom) <= 0.75)

                    Text(DesktopChatAppearance.clamped(macChatZoom).formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                        .frame(width: 48)
                        .accessibilityLabel("Chat zoom")
                        .accessibilityValue(DesktopChatAppearance.clamped(macChatZoom).formatted(.percent.precision(.fractionLength(0))))
                        .accessibilityIdentifier("settings.chatZoom")

                    Button {
                        macChatZoom = DesktopChatAppearance.adjusted(macChatZoom, by: 0.25)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Zoom in chat")
                    .accessibilityIdentifier("settings.chatZoom.increase")
                    .disabled(DesktopChatAppearance.clamped(macChatZoom) >= 2)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Actual Size") { macChatZoom = DesktopChatAppearance.defaultZoom }
                    .accessibilityIdentifier("settings.chatZoom.reset")
            }
        } header: {
            Text("Chat appearance")
        } footer: {
            Text("Zooms the chat page like Safari; it reflows at the window’s width. Adjust from 75% to 200%. This Mac only; your conversation stays open.")
        }
    }

    /// Saved servers are configuration: managed here, not from the Agents header.
    private var connectionsSection: some View {
        let issues = PhoneHubConnectionsView.issueCount(connections: connections, aggregate: aggregate)
        let saved = connections.connections.count
        return Section {
            NavigationLink {
                PhoneHubConnectionsView(connections: connections, aggregate: aggregate, onOpenChat: { sourceID, url in
                    showingSettings = false
                    openPhoneChat(sourceID, url)
                })
            } label: {
                LabeledContent {
                    if issues > 0 {
                        Label("\(issues)", systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Text(saved == 0 ? "None" : "\(saved)")
                    }
                } label: {
                    Label("Connections", systemImage: "server.rack")
                }
            }
            .accessibilityValue(issues > 0 ? "\(issues) need attention" : (saved == 0 ? "None saved" : "\(saved) saved"))
            .accessibilityIdentifier("settings.connections")
        }
    }

    /// One agent across all connections. Choosing it never switches the chat;
    /// only running the shortcut does.
    private var voiceShortcutSection: some View {
        let nodes = aggregate.nodes.filter { !$0.source.isLinkedDevices }
        let savedIsListed = voiceTarget.map { target in nodes.contains { $0.source.id == target.sourceID && $0.node.id == target.nodeID } } ?? true
        return Section {
            Picker("Agent", selection: Binding(
                get: { voiceTarget?.key ?? "" },
                set: { key in
                    guard let row = nodes.first(where: { "\($0.source.id.uuidString)|\($0.node.id)" == key }) else {
                        if key.isEmpty { setVoiceTarget(nil) }
                        return
                    }
                    setVoiceTarget(VoiceShortcutTarget(sourceID: row.source.id, nodeID: row.node.id,
                                                       name: row.node.name, path: row.node.new_session_path))
                }
            )) {
                Text("None").tag("")
                if !savedIsListed, let voiceTarget {
                    Text(voiceTarget.name).tag(voiceTarget.key)
                }
                ForEach(aggregate.sources) { source in
                    let rows = nodes.filter { $0.source.id == source.id }
                    if !rows.isEmpty {
                        Section(source.connection.name) {
                            ForEach(rows) { row in
                                Text(row.node.name).tag("\(row.source.id.uuidString)|\(row.node.id)")
                            }
                        }
                    }
                }
            }
            .accessibilityIdentifier("settings.voiceAgent")
            Button("Start live conversation") { voiceLaunches.requestLaunch() }
                .disabled(voiceTarget == nil)
                .accessibilityIdentifier("settings.voiceTest")
        } header: {
            Text("Voice shortcut")
        } footer: {
            Text(AppPlatform.isMac ? "Run with Siri or Shortcuts." : "Runs from the Action Button, Siri or Shortcuts.")
        }
    }

    private func setVoiceTarget(_ target: VoiceShortcutTarget?) {
        voiceTarget = target
        VoiceShortcutTarget.save(target, to: HubFixture.defaults)
    }

    private var deviceToolsSection: some View {
        Section {
            Toggle("Share device tools", isOn: $deviceTools.isEnabled)
                .accessibilityIdentifier("deviceToolsToggle")
            NavigationLink("What’s shared") { DeviceToolsInfoView() }
                .accessibilityIdentifier("deviceToolsInfo")
        } header: {
            Text("Device tools")
        } footer: {
            Text("Let agents use this \(DeviceToolPlatform.current == .mac ? DeviceToolPlatform.current.name : NativeDevice.model) while you chat.")
        }
    }

    private func revealPendingPushIfOwned() {
        guard !isFixture, let navigation = push.pendingNavigation, let pushWindowID,
              navigation.windowID == pushWindowID else { return }
        if let owner = navigation.connectionID, owner != connections.selectedID {
            // Another saved connection owns this page: switch to it the same
            // way Agents opens a chat. A connection removed since the tap
            // simply leaves the app where it is.
            push.navigationHandled(navigation.id)
            guard connections.connections.contains(where: { $0.id == owner }) else { return }
            openPushOnConnection(owner, navigation.url)
            return
        }
        guard navigation.canPresent(in: pushWindowID, server: address) else {
            // A page outside the selected mount can never be presented here;
            // drop it rather than let it linger and hijack a later visit.
            if address != nil { push.navigationHandled(navigation.id) }
            return
        }
        workspaceChosen = true
        showingSettings = false
        showingHub = false
        if let destination = push.pendingNavigation?.url { pendingChat = makeChatContext(for: destination) }
        resumeParkedBrowser(automatically: false)
        selectTab(.chat)
    }

    private func beginVoiceLaunch(_ id: UUID) {
        // Fixtures never register a push window; they run as a single key scene.
        guard voiceRequest == nil, effectiveScenePhase == .active, let windowID = pushWindowID ?? (isFixture ? "fixture" : nil),
              voiceLaunches.claim(id, windowID: windowID, isKeyScene: isFixture || push.isKeyScene(windowID)) else { return }
        guard let target = voiceTarget, let source = aggregate.source(target.sourceID), source.isActive,
              !source.browserRevoked,
              let destination = aggregate.destination(path: target.path, sourceID: source.id, nodeID: target.nodeID) else {
            voiceLaunchError = voiceTarget == nil
                ? "Choose an agent for the voice shortcut in Settings."
                : "The voice shortcut’s agent isn’t available. Sign in to its connection or choose another agent in Settings."
            voiceLaunches.finish()
            return
        }
        showingSettings = false
        showingHub = false
        showingMusic = false
        showingListen = false
        showingPlayer = false
        voiceLaunchError = nil
        Task { @MainActor in
            await source.prepareBrowserAuthentication()
            guard voiceLaunches.request == id else { return }
            guard source.isActive, !source.browserRevoked, aggregate.source(source.id) === source else {
                voiceLaunchError = "Connection authorization changed. Sign in again before starting voice."
                voiceLaunches.finish()
                return
            }
            // Same selection path as opening an agent from the Agents tab.
            if connections.selectedID != source.id {
                connections.select(source.id)
                hubDestination = HubBrowserDestination(url: destination, sourceID: source.id)
            }
            serverURL = source.connection.url.absoluteString
            hubRole = source.connection.kind == .hub ? .hub : .direct
            hubBrowserRevoked = false
            loadError = nil
            loginError = nil
            loginRequired = false
            workspaceChosen = true
            voiceRequest = VoiceBrowserLaunch(id: id, url: destination)
            pendingChat = makeChatContext(for: destination, source: source)
            resumeParkedBrowser(automatically: false)
            selectTab(.chat)
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
                Button(AppPlatform.isMac ? "Allow in System Settings" : "Allow in iOS Settings") {
                    if let url = NativeApp.notificationSettingsURL { NativeApp.open(url) }
                }
            }
        } footer: {
            if push.authorization == .denied {
                Text(AppPlatform.isMac ? "Notifications are blocked for term-llm in System Settings."
                                       : "Notifications are blocked for term-llm in iOS Settings.")
            }
            if push.pendingCleanupCount > 0 {
                Text("^[\(push.pendingCleanupCount) agent](inflect: true) may still send notifications until you open it while signed in.")
            }
            if let issue = push.storageIssue { Text(issue) }
            if let issue = push.navigationIssue { Text(issue) }
        }
    }
}

#if os(iOS)
/// Resolve the actual containing scene even on the unconfigured/setup screen;
/// global shortcut/error handling must not sample an arbitrary current scene.
/// (The Mac app's reader is in TermLLMMac/MacWorkspace.swift.)
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
#endif
