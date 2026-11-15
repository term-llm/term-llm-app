import XCTest
import UIKit

/// Real native UI + loopback HTTP protocol fixtures, not live agents or auth.
final class PhoneHubUITests: XCTestCase {
    private var app: XCUIApplication!
    private let fixture = "http://localhost:8767"

    @MainActor
    private func required(_ element: XCUIElement, timeout: TimeInterval = 30,
                          file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        // XCTest's waiters poll at 1 s and only check after the first second;
        // skip the wait entirely when the element is already present.
        let found = element.exists || element.waitForExistence(timeout: timeout)
        if !found {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "phone-hub-missing-element-hierarchy-DEMO-FIXTURE-LOCAL"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            shot("failure")
        }
        XCTAssertTrue(found, "Required phone Hub element missing", file: file, line: line)
        return element
    }

    @MainActor
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "phone-hub-" + name + "-DEMO-FIXTURE-LOCAL"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Matches `PhoneHubFixture.seedSources`; seeded connections have fixed IDs.
    private static let seededIDs = [
        "work": "00000000-0000-4000-8000-000000000001",
        "home": "00000000-0000-4000-8000-000000000002",
        "direct": "00000000-0000-4000-8000-000000000003",
        "slow": "00000000-0000-4000-8000-000000000004",
    ]
    private func id(_ key: String) -> String { Self.seededIDs[key]! }

    /// Fixture source modes are global; never inherit another test's state.
    override func setUp() async throws {
        for source in Self.seededIDs.keys {
            var request = URLRequest(url: URL(string: "http://localhost:8767/__control/" + source + "/healthy")!)
            request.httpMethod = "POST"
            request.httpBody = Data("{}".utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "Fixture server must be running")
        }
    }

    /// `seed` preloads fixture connections (in order; the first is selected)
    /// instead of typing them into the editor. Only the editor tests type.
    @MainActor
    private func launch(reset: Bool, seed: [String] = [], arguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = arguments
        app.launchEnvironment["TERMLLM_PHONE_HUB_FIXTURE_URL"] = fixture + "/"
        app.launchEnvironment["TERMLLM_PHONE_HUB_FIXTURE_RESET"] = reset ? "1" : "0"
        if !seed.isEmpty { app.launchEnvironment["TERMLLM_PHONE_HUB_FIXTURE_SEED"] = seed.joined(separator: ",") }
        app.launch()
        _ = required(app.staticTexts["phoneHub.fixtureBanner"])
    }

    @MainActor
    private func reveal(_ element: XCUIElement, upwards: Bool = true,
                        file: StaticString = #filePath, line: UInt = #line) {
        // Inside the Settings sheet a downward swipe at the top dismisses the
        // sheet; Connections opens scrolled to the top, so only scroll down.
        let inSheet = app.buttons["settings.done"].exists || app.navigationBars["Connections"].exists ||
            app.descendants(matching: .any)["phoneHub.connectionDetail"].firstMatch.exists
        for direction in inSheet ? [true] : [upwards, !upwards] {
            for _ in 0..<8 {
                if element.exists {
                    let rect = element.frame
                    // isHittable can itself fail for invalid/offscreen AX frames.
                    let visible = !rect.isEmpty && !rect.isInfinite && !rect.isNull &&
                        rect.midX.isFinite && rect.midY.isFinite &&
                        app.frame.contains(CGPoint(x: rect.midX, y: rect.midY))
                    if visible && element.isHittable { return }
                }
                if direction { app.swipeUp() } else { app.swipeDown() }
            }
        }
        _ = required(element, file: file, line: line)
        XCTFail("Cannot reveal actual native element", file: file, line: line)
    }

    /// Connections are managed in Settings, not from the Agents header.
    @MainActor
    private func openConnections() {
        backToConnections()
        if app.navigationBars["Connections"].exists { return }
        if !app.buttons["settings.done"].exists {
            if app.descendants(matching: .any)["workspace.shell"].firstMatch.exists {
                showWorkspaceSidebar()
                required(app.buttons["workspace.settings"]).tap()
            } else {
                required(app.buttons["phoneHub.settings"]).tap()
            }
        }
        required(app.buttons["settings.connections"]).tap()
        _ = required(app.navigationBars["Connections"])
    }

    /// Every connection action lives on its detail page, pushed from the list.
    @MainActor
    private func openConnection(_ id: String) {
        openConnections()
        backToConnections()
        let row = app.buttons["phoneHub.source." + id]
        reveal(row)
        row.tap()
        _ = required(app.descendants(matching: .any)["phoneHub.connectionDetail"].firstMatch)
    }

    @MainActor
    private func backToConnections() {
        guard app.descendants(matching: .any)["phoneHub.connectionDetail"].firstMatch.exists else { return }
        app.navigationBars.buttons["Connections"].firstMatch.tap()
        _ = required(app.navigationBars["Connections"])
    }

    @MainActor
    private func closeConnections() {
        backToConnections()
        let connectionsBar = app.navigationBars["Connections"]
        if connectionsBar.exists {
            connectionsBar.buttons["Settings"].tap()
            _ = required(app.buttons["settings.done"])
        }
        if app.buttons["settings.done"].exists {
            app.buttons["settings.done"].tap()
        }
        if app.descendants(matching: .any)["workspace.shell"].firstMatch.exists {
            _ = required(app.staticTexts["workspace.header.title"])
        } else {
            _ = required(app.staticTexts["phoneHub.home"])
        }
    }

    @MainActor
    private func addConnection(_ name: String, path: String) {
        openConnections()
        let add = app.buttons["phoneHub.connections.add"]
        reveal(add, upwards: false)
        add.tap()
        let nameField = required(app.textFields["phoneHub.connection.name"])
        nameField.tap()
        nameField.typeText(name)
        let address = required(app.textFields["phoneHub.connection.url"])
        address.tap()
        address.typeText(fixture + path)
        XCTAssertFalse(app.segmentedControls["phoneHub.connection.kind"].exists)
        required(app.buttons["phoneHub.connection.save"]).tap()
        required(app.buttons["phoneHub.connection.done"]).tap()
        closeConnections()
    }

    @MainActor
    private func sourceID(_ name: String) -> String {
        openConnections()
        defer { closeConnections() }
        reveal(app.staticTexts[name].firstMatch)
        let prefix = "phoneHub.source."
        let candidates = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
        for element in candidates.allElementsBoundByIndex where element.label.contains(name) {
            let id = String(element.identifier.dropFirst(prefix.count))
            if UUID(uuidString: id) != nil { return id }
        }
        XCTFail("Native source identity missing for fixture source " + name)
        return "missing-source"
    }

    @MainActor
    private func panel(_ name: String) {
        closeConnections()
        let segment = required(app.buttons["phoneHub." + name])
        reveal(segment, upwards: false)
        segment.tap()
        guard !segment.isSelected else { return }
        let selection = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: segment)
        XCTAssertEqual(XCTWaiter.wait(for: [selection], timeout: 5), .completed, "The view switcher must select the requested panel")
    }

    @MainActor
    private func setShowOfflineAgents(_ on: Bool) {
        openConnections()
        let toggle = app.switches["phoneHub.showOfflineAgents"]
        reveal(toggle)
        if (toggle.value as? String == "1") != on {
            // Tap the switch knob; the row label alone does not flip it.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        XCTAssertEqual(toggle.value as? String, on ? "1" : "0")
        closeConnections()
    }

    @MainActor
    private func control(_ source: String, _ state: String) async throws {
        var request = URLRequest(url: URL(string: fixture + "/__control/" + source + "/" + state)!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    @MainActor
    func testAgentsViewMenuCanSwitchRepeatedly() throws {
        continueAfterFailure = false
        launch(reset: true, seed: ["work"])
        panel("attention")
        _ = required(app.staticTexts["Work result"])
        panel("sessions")
        _ = required(app.staticTexts["Work result"])
        panel("nodes")
        _ = required(app.staticTexts["Work agent"])
        panel("attention")
        _ = required(app.staticTexts["Work result"])
    }

    @MainActor
    func testChatTabRequiresAnExplicitAgentBeforeOpeningAPage() throws {
        continueAfterFailure = false
        launch(reset: true)
        for tab in ["agents", "chat", "music", "podcasts"] {
            XCTAssertTrue(required(app.tabBars.buttons[tab.capitalized]).isHittable)
        }
        required(app.tabBars.buttons["Chat"]).tap()
        _ = required(app.buttons["chat.chooseAgent"])
        XCTAssertEqual(app.webViews.count, 0, "Chat must not pick a server root or arbitrary agent")
        shot("chat-choose-agent")
        required(app.buttons["chat.chooseAgent"]).tap()
        addConnection("Work Hub", path: "/work/")
        required(app.tabBars.buttons["Chat"]).tap()
        _ = required(app.buttons["chat.chooseAgent"])
        XCTAssertEqual(app.webViews.count, 0, "Saving a connection is not choosing a conversation")
        required(app.tabBars.buttons["Music"]).tap()
        _ = required(app.navigationBars["Music"])
        XCTAssertFalse(app.buttons["Done"].exists, "A tab is not a modal Music sheet")
        shot("music-tab")
        required(app.tabBars.buttons["Podcasts"]).tap()
        _ = required(app.navigationBars["Podcasts"])
        XCTAssertFalse(app.buttons["Done"].exists)
        shot("podcasts-tab")
        required(app.tabBars.buttons["Agents"]).tap()
        _ = required(app.staticTexts["phoneHub.home"])
    }

    @MainActor
    func testContextualChatTabKeepsExactPageAndDraftAcrossAllDestinations() throws {
        continueAfterFailure = false
        launch(reset: true, seed: ["work"])
        let work = id("work")
        required(app.buttons["phoneHub.node." + work + ".shared.new"]).tap()
        _ = required(app.webViews.staticTexts["Work fixture chat"])
        if app.buttons["Got it"].exists { app.buttons["Got it"].tap() }
        required(app.webViews.links["Open existing fixture conversation"]).tap()
        _ = required(app.webViews.staticTexts["/work/node/shared/chat/1"])
        let draft = required(app.webViews.textFields["Fixture draft"])
        draft.tap()
        draft.typeText("Keep the exact conversation")
        XCTAssertEqual(app.tabBars.buttons["Chat"].label, "Chat", "Tabs describe destinations, not the active agent")
        XCTAssertFalse(app.buttons["phoneHub.settings"].isHittable, "Chat has no app-level header")
        shot("chat-context-work-agent")
        for (tab, title) in [("music", "Music"), ("podcasts", "Podcasts")] {
            required(app.tabBars.buttons[tab.capitalized]).tap()
            _ = required(app.navigationBars[title])
            required(app.tabBars.buttons["Chat"]).tap()
            _ = required(app.webViews.staticTexts["/work/node/shared/chat/1"])
            XCTAssertEqual(app.webViews.textFields["Fixture draft"].value as? String, "Keep the exact conversation")
            XCTAssertEqual(app.tabBars.buttons["Chat"].label, "Chat", "Tabs describe destinations, not the active agent")
            XCTAssertFalse(app.buttons["phoneHub.settings"].isHittable)
            XCTAssertFalse(app.navigationBars[title].isHittable, "An inactive media navigation bar must not cover the agent header")
        }
        required(app.tabBars.buttons["Agents"]).tap()
        _ = required(app.staticTexts["phoneHub.home"])
        shot("agents-four-tabs")
        required(app.tabBars.buttons["Chat"]).tap()
        _ = required(app.webViews.staticTexts["/work/node/shared/chat/1"])
        XCTAssertEqual(app.webViews.textFields["Fixture draft"].value as? String, "Keep the exact conversation")
        shot("chat-retained-exact-page")
    }

    // MARK: iPad / Designed for iPad on Mac workspace

    @MainActor
    private func requireWorkspaceDevice() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad || ProcessInfo.processInfo.isiOSAppOnMac,
                          "Workspace coverage requires an iPad or Designed for iPad on Mac; keep the phone journey unchanged")
    }

    /// A portrait/narrow iPad uses an overlay sidebar; do not require a particular
    /// simulator size, rotate the developer's device, or fall back to phone tabs.
    @MainActor
    private func showWorkspaceSidebar() {
        if !app.buttons["appTab.agents"].exists || !app.buttons["appTab.agents"].isHittable {
            let candidates = app.buttons.matching(NSPredicate(format: "identifier IN %@",
                ["workspace.sidebar.toggle", "workspace.toggleSidebar"])).allElementsBoundByIndex
            let toggle = candidates.first(where: { $0.isHittable }) ?? candidates.first
            XCTAssertNotNil(toggle, "A narrow workspace must expose a visible sidebar control")
            guard let toggle else { return }
            required(toggle, timeout: 10).tap()
        }
        for tab in ["agents", "chat", "music", "podcasts"] {
            XCTAssertTrue(required(app.buttons["appTab." + tab], timeout: 10).isHittable,
                          "Workspace destinations must be accessible sidebar buttons")
        }
        XCTAssertEqual(app.tabBars.count, 0, "An iPad workspace must not show the phone tab bar")
    }

    @MainActor
    private func selectWorkspaceDestination(_ tab: String) {
        showWorkspaceSidebar()
        let destination = required(app.buttons["appTab." + tab], timeout: 10)
        destination.tap()
        // Compact sidebar buttons disappear after selection, so assert the
        // destination's own UI rather than selection on an offscreen button.
    }

    @MainActor
    private func requireWorkspaceTitle(_ title: String) {
        let titles = app.staticTexts.matching(identifier: "workspace.header.title")
        let visible = titles.allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertEqual(visible.count, 1, "Only the active destination owns a visible quiet native root title")
        XCTAssertEqual(visible.first?.label, title)
        XCTAssertFalse(app.navigationBars[title].isHittable,
                       "Workspace roots must not duplicate their quiet header with a native navigation bar")
    }

    @MainActor
    func testWorkspaceSidebarPanelsSettingsAndAgentBackNavigation() throws {
        try requireWorkspaceDevice()
        continueAfterFailure = false
        executionTimeAllowance = 120
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        launch(reset: true, seed: ["work"])
        _ = required(app.descendants(matching: .any)["workspace.shell"].firstMatch, timeout: 10)
        _ = required(app.descendants(matching: .any)["workspace.header"].firstMatch, timeout: 10)
        requireWorkspaceTitle("Agents")
        XCTAssertFalse(app.buttons["phoneHub.settings"].isHittable,
                       "The workspace uses sidebar Settings, not the phone toolbar")
        showWorkspaceSidebar()
        shot("workspace-sidebar-ipad")
        selectWorkspaceDestination("agents")

        // Exercise the actual pinned panel controls without scrolling them
        // into view: Agents, Attention and Sessions must stay accessible.
        for (panel, content) in [("attention", "Work result"), ("sessions", "Work result"), ("nodes", "Work agent")] {
            let button = required(app.buttons["phoneHub." + panel], timeout: 10)
            XCTAssertTrue(button.isHittable)
            button.tap()
            _ = required(app.staticTexts[content].firstMatch, timeout: 10)
            requireWorkspaceTitle("Agents")
        }
        shot("workspace-agents-panels-ipad")

        // Exercise the same Settings/Connections helpers used by the phone
        // journey; their workspace branch opens the actual sidebar Settings.
        openConnections()
        _ = required(app.navigationBars["Connections"], timeout: 10)
        shot("workspace-settings-connections-ipad")
        closeConnections()
        requireWorkspaceTitle("Agents")

        let agent = required(app.buttons["phoneHub.node." + id("work") + ".shared"], timeout: 10)
        agent.tap()
        _ = required(app.descendants(matching: .any)["phoneHub.agent"].firstMatch, timeout: 10)
        let navigation = required(app.navigationBars["Work agent"], timeout: 10)
        XCTAssertTrue(required(navigation.buttons["Agents"], timeout: 10).isHittable,
                      "A pushed agent must keep native Back even though the root navigation bar is hidden")
        shot("workspace-agent-pushed-ipad")
        navigation.buttons["Agents"].tap()
        requireWorkspaceTitle("Agents")
        XCTAssertTrue(required(app.buttons["phoneHub.node." + id("work") + ".shared"], timeout: 10).isHittable)
        shot("workspace-agent-back-ipad")
    }

    @MainActor
    func testWorkspaceFleetKeepsCollidingAgentRoutesSeparate() throws {
        try requireWorkspaceDevice()
        continueAfterFailure = false
        launch(reset: true, seed: ["work", "home"])
        _ = required(app.descendants(matching: .any)["phoneHub.overview.totals"].firstMatch)
        for source in ["work", "home"] {
            let node = "phoneHub.node." + id(source) + ".shared"
            let open = required(app.buttons[node])
            reveal(open)
            open.tap()
            _ = required(app.descendants(matching: .any)["phoneHub.agent"].firstMatch)
            let name = source == "work" ? "Work agent" : "Home agent"
            required(app.navigationBars[name].buttons["Agents"]).tap()
            let compose = required(app.buttons[node + ".new"])
            reveal(compose)
            compose.tap()
            _ = required(app.webViews.staticTexts[source == "work" ? "Work fixture chat" : "Home fixture chat"])
            selectWorkspaceDestination("agents")
        }
        shot("workspace-fleet-ipad")
    }

    @MainActor
    func testWorkspaceRetainsExactFixtureConversationAndDraftAcrossDestinations() throws {
        try requireWorkspaceDevice()
        continueAfterFailure = false
        executionTimeAllowance = 120
        launch(reset: true, seed: ["work"])
        required(app.buttons["phoneHub.node." + id("work") + ".shared.new"], timeout: 10).tap()
        _ = required(app.webViews.staticTexts["Work fixture chat"], timeout: 10)
        if app.buttons["Got it"].exists { app.buttons["Got it"].tap() }
        required(app.webViews.links["Open existing fixture conversation"], timeout: 10).tap()
        let route = "/work/node/shared/chat/1"
        _ = required(app.webViews.staticTexts[route], timeout: 10)
        let draft = "workspace314159"
        let input = required(app.webViews.textFields["Fixture draft"], timeout: 10)
        input.tap()
        input.typeText(draft)
        XCTAssertEqual(input.value as? String, draft)
        // WebKit may expose nested AX WebView wrappers for one document when
        // hosted in a retained UIKit container. Compare with the initial shape;
        // route + edited DOM draft are the black-box document-retention proof.
        let visibleWebViewCount = app.webViews.count
        XCTAssertGreaterThan(visibleWebViewCount, 0)
        shot("workspace-chat-draft-ipad")

        // No permission/auth controls, searches, or playback actions are needed.
        // The fixture has no JS document marker: its exact route + unsaved DOM
        // input are the available black-box retention evidence, not a live-server claim.
        for (destination, title) in [("agents", "Agents"), ("music", "Music"), ("podcasts", "Podcasts")] {
            selectWorkspaceDestination(destination)
            requireWorkspaceTitle(title)
            XCTAssertEqual(app.webViews.count, 0, "The retained inactive Chat must be detached from visible UI")
            XCTAssertFalse(app.webViews.textFields["Fixture draft"].exists,
                           "An inactive Chat must not remain accessible over a native destination")
            shot("workspace-" + destination + "-ipad")
            selectWorkspaceDestination("chat")
            XCTAssertEqual(app.webViews.count, visibleWebViewCount, "Switching destinations must not add WebView wrappers or duplicate Chat documents")
            _ = required(app.webViews.staticTexts["Work fixture chat"], timeout: 10)
            _ = required(app.webViews.staticTexts[route], timeout: 10)
            XCTAssertEqual(required(app.webViews.textFields["Fixture draft"], timeout: 10).value as? String, draft,
                           "Return to the exact conversation with its unsaved DOM draft, not a reloaded fixture page")
            XCTAssertFalse(app.staticTexts.matching(identifier: "workspace.header.title").allElementsBoundByIndex.contains { $0.isHittable },
                           "Chat owns its web header; no visible native workspace title may cover it")
            XCTAssertFalse(app.navigationBars[title].isHittable,
                           "Inactive native navigation must not cover Chat")
        }
        shot("workspace-chat-retained-exact-page-ipad")
    }

    @MainActor
    func testRemovingCurrentConnectionDoesNotRetargetChatToAnotherAgent() throws {
        continueAfterFailure = false
        launch(reset: true, seed: ["work", "home"])
        let work = id("work")
        required(app.buttons["phoneHub.node." + work + ".shared.new"]).tap()
        _ = required(app.webViews.staticTexts["Work fixture chat"])
        required(app.tabBars.buttons["Agents"]).tap()
        openConnection(work)
        XCTAssertFalse(app.buttons["phoneHub.select." + work].exists, "Chat's connection is not a setting")
        required(app.buttons["phoneHub.remove." + work]).tap()
        required(app.buttons["phoneHub.remove.confirm"].firstMatch).tap()
        _ = required(app.navigationBars["Connections"])
        XCTAssertFalse(app.buttons["phoneHub.source." + work].exists)
        closeConnections()
        required(app.tabBars.buttons["Chat"]).tap()
        _ = required(app.buttons["chat.chooseAgent"])
        XCTAssertEqual(app.tabBars.buttons["Chat"].label, "Chat")
        XCTAssertFalse(app.webViews.staticTexts["Work fixture chat"].exists)
        XCTAssertFalse(app.webViews.staticTexts["Home fixture chat"].exists, "Do not pick a fallback agent")
    }

    @MainActor
    func testNativeTabsRemainUsableWithLargeText() throws {
        continueAfterFailure = false
        launch(reset: true, arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        for title in ["Agents", "Chat", "Music", "Podcasts"] {
            let tab = required(app.tabBars.buttons[title])
            XCTAssertTrue(tab.isHittable)
            XCTAssertGreaterThanOrEqual(tab.frame.height, 44)
        }
        required(app.tabBars.buttons["Chat"]).tap()
        let chooseAgent = required(app.buttons["chat.chooseAgent"])
        for _ in 0..<5 {
            if chooseAgent.isHittable && chooseAgent.frame.maxY <= app.tabBars.firstMatch.frame.minY { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(chooseAgent.isHittable)
        XCTAssertLessThanOrEqual(chooseAgent.frame.maxY, app.tabBars.firstMatch.frame.minY,
                                 "The large-text action must scroll clear of the tab bar")
        shot("native-tabs-large-text-chat")
        required(app.tabBars.buttons["Agents"]).tap()
        shot("native-tabs-large-text-agents")
    }

    @MainActor
    func testConnectionSetupExplainsFailureAndAllowsRetry() throws {
        continueAfterFailure = false
        launch(reset: true)
        // With nothing configured, the pinned banner offers the connection.
        let add = required(app.buttons["phoneHub.addConnection"])
        XCTAssertTrue(add.isHittable)
        _ = required(app.staticTexts["No connections yet"])
        shot("home-no-connections-banner")
        add.tap()
        XCTAssertFalse(app.segmentedControls["phoneHub.connection.kind"].exists)
        XCTAssertFalse(required(app.buttons["phoneHub.connection.save"]).isEnabled)
        shot("connection-ready")
        let address = required(app.textFields["phoneHub.connection.url"])
        let invalid = fixture + "/unknown/"
        address.tap()
        address.typeText(invalid)
        required(app.buttons["phoneHub.connection.save"]).tap()
        _ = required(app.staticTexts["Couldn’t connect yet"])
        XCTAssertTrue(app.textFields["phoneHub.connection.url"].exists)
        shot("connection-recovery")
        required(app.buttons["phoneHub.connection.clearAddress"]).tap()
        address.typeText(fixture + "/work/")
        app.swipeUp()
        reveal(app.buttons["phoneHub.connection.retry"])
        required(app.buttons["phoneHub.connection.retry"]).tap()
        _ = required(app.staticTexts["phoneHub.connection.success"])
        shot("connection-success")
        required(app.buttons["phoneHub.connection.done"]).tap()
        _ = sourceID("localhost")
    }

    @MainActor
    func testNodesDefaultToOnlineAndConnectionsCanRevealOfflineNodes() async throws {
        continueAfterFailure = false
        try await control("work", "offline")
        launch(reset: true, seed: ["work"])
        let work = id("work")
        panel("nodes")
        let offlineNode = app.buttons["phoneHub.node." + work + ".shared"]
        XCTAssertFalse(app.buttons["phoneHub.nodes.showAll"].exists, "The list has no offline filter control")
        _ = required(app.staticTexts["No agents online"])
        XCTAssertFalse(offlineNode.exists)
        shot("nodes-online-only-empty")
        setShowOfflineAgents(true)
        reveal(offlineNode)
        XCTAssertFalse(offlineNode.isEnabled)
        shot("nodes-show-all")
        setShowOfflineAgents(false)
        XCTAssertFalse(offlineNode.exists)
        addConnection("Home Hub", path: "/home/")
        let home = sourceID("Home Hub")
        panel("nodes")
        reveal(app.buttons["phoneHub.node." + home + ".shared"])
        XCTAssertFalse(offlineNode.exists)
        shot("nodes-online-only")
    }

    @MainActor
    func testRefreshAppliesDeltaWithoutMovingVisibleNodes() async throws {
        continueAfterFailure = false
        launch(reset: true, seed: ["work", "home"])
        let home = id("home")
        panel("nodes")
        let anchor = app.buttons["phoneHub.node." + home + ".shared"]
        reveal(anchor)
        let baseline = anchor.frame.minY
        try await control("work", "delayed-update")
        let refresh = app.buttons["phoneHub.refresh"]
        for _ in 0..<2 {
            refresh.tap()
            XCTAssertTrue(anchor.exists, "Keep existing rows visible during refresh")
            XCTAssertEqual(anchor.frame.minY, baseline, accuracy: 2, "Loading feedback must not shift the list")
            let finished = NSPredicate(format: "enabled == true")
            let wait = XCTNSPredicateExpectation(predicate: finished, object: refresh)
            await fulfillment(of: [wait], timeout: 10)
            _ = required(app.staticTexts["Work refreshed agent"])
            XCTAssertEqual(anchor.frame.minY, baseline, accuracy: 2, "Delta updates must preserve the visible scroll anchor")
        }
        shot("refresh-delta-preserves-position")
    }

    @MainActor
    func testSettingsHasNoServerEditorAndDoneWorksWithoutConnection() throws {
        continueAfterFailure = false
        launch(reset: true)
        required(app.buttons["phoneHub.settings"]).tap()
        XCTAssertFalse(app.textFields["serverAddress"].exists)
        XCTAssertFalse(app.staticTexts["Server"].exists)
        XCTAssertFalse(app.switches["deviceToolsToggle"].exists)
        let done = required(app.buttons["settings.done"])
        XCTAssertTrue(done.isEnabled)
        shot("settings-app-preferences-only")
        done.tap()
        _ = required(app.buttons["phoneHub.addConnection"])
        app.terminate()
        launch(reset: true, seed: ["work"])
        required(app.buttons["phoneHub.settings"]).tap()
        XCTAssertFalse(app.textFields["serverAddress"].exists)
        XCTAssertFalse(app.buttons["settings.toolsConnection"].exists, "No per-connection settings picker")
        _ = required(app.buttons["settings.voiceAgent"])
        reveal(app.switches["deviceToolsToggle"])
        _ = required(app.switches["deviceToolsToggle"])
        required(app.buttons["deviceToolsInfo"]).tap()
        _ = required(app.staticTexts["Music"])
        shot("settings-device-tools-info")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        required(app.buttons["settings.done"]).tap()
        _ = required(app.buttons["phoneHub.node." + id("work") + ".shared"])
    }

    @MainActor
    func testNodesFirstHomeAndResumeKeepTheRetainedConversation() throws {
        continueAfterFailure = false
        launch(reset: true, seed: ["work", "home"])
        let work = id("work"), home = id("home")
        let workNode = required(app.buttons["phoneHub.node." + work + ".shared"])
        XCTAssertTrue(workNode.isHittable, "Nodes must be visible without scrolling through connection administration")
        XCTAssertFalse(app.buttons["phoneHub.addConnection"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "phoneHub.settings").count, 1)
        XCTAssertFalse(app.buttons["phoneHub.edit." + work].exists)
        shot("home-nodes-first")
        required(app.buttons["phoneHub.node." + work + ".shared.new"]).tap()
        _ = required(app.webViews.staticTexts["Work fixture chat"])
        let draft = required(app.webViews.textFields["Fixture draft"])
        draft.tap()
        draft.typeText("Keep this draft")
        required(app.tabBars.buttons["Agents"]).tap()
        openConnections()
        shot("connections-management")
        XCTAssertFalse(app.buttons["phoneHub.features." + home].exists)
        XCTAssertFalse(app.buttons["phoneHub.features." + work].exists)
        closeConnections()
        required(app.buttons["phoneHub.settings"]).tap()
        // Choosing the voice agent from another connection must not switch the chat.
        required(app.buttons["settings.voiceAgent"]).tap()
        required(app.buttons["Home agent"]).tap()
        let deviceToggle = app.switches["deviceToolsToggle"]
        reveal(deviceToggle)
        _ = required(deviceToggle)
        shot("settings-voice-and-device-tools")
        required(app.buttons["settings.done"]).tap()
        required(app.tabBars.buttons["Chat"]).tap()
        _ = required(app.webViews.staticTexts["Work fixture chat"])
        XCTAssertEqual(app.webViews.textFields["Fixture draft"].value as? String, "Keep this draft", "Resume must reveal the same DOM, not navigate or reload")
        shot("chat-resumed-with-draft")
        XCTAssertFalse(app.buttons["phoneHub.settings"].isHittable, "Chat uses Back to Hub, not a second Settings entry")
        required(app.tabBars.buttons["Agents"]).tap()
        required(app.buttons["phoneHub.settings"]).tap()
        reveal(app.switches["deviceToolsToggle"])
        _ = required(app.switches["deviceToolsToggle"])
        shot("settings-app-voice-and-tools")
        required(app.buttons["settings.done"]).tap()
    }

    @MainActor
    func testVoiceShortcutOpensTheChosenAgentOnItsConnection() async throws {
        continueAfterFailure = false
        launch(reset: true, seed: ["work", "home"])
        let work = id("work")
        required(app.buttons["phoneHub.node." + work + ".shared.new"]).tap()
        _ = required(app.webViews.staticTexts["Work fixture chat"])
        required(app.tabBars.buttons["Agents"]).tap()
        required(app.buttons["phoneHub.settings"]).tap()
        XCTAssertFalse(required(app.buttons["settings.voiceTest"]).isEnabled, "No agent chosen yet")
        required(app.buttons["settings.voiceAgent"]).tap()
        required(app.buttons["Home agent"]).tap()
        shot("settings-voice-agent-chosen")
        required(app.buttons["settings.voiceTest"]).tap()
        _ = required(app.webViews.staticTexts["Home fixture chat"])
        XCTAssertFalse(app.webViews.staticTexts["Work fixture chat"].exists, "Voice opens the chosen agent, not the current chat")
    }

    @MainActor
    func testSavedConnectionsAndUnifiedViews() throws {
        continueAfterFailure = false
        launch(reset: true, seed: ["work", "home"])
        // One connection goes through the editor so persistence covers a real save.
        addConnection("Laptop", path: "/direct/")
        let work = id("work"), home = id("home"), direct = sourceID("Laptop")
        XCTAssertEqual(Set([work, home, direct]).count, 3)
        panel("nodes")
        let workNode = app.buttons["phoneHub.node." + work + ".shared"].firstMatch
        reveal(workNode)
        let homeNode = app.buttons["phoneHub.node." + home + ".shared"].firstMatch
        reveal(homeNode)
        shot("02-two-hubs-and-direct-node")
        // Exercise the real source-aware navigation, not just native cached rows.
        for (id, title) in [(work, "Work"), (home, "Home"), (direct, "Laptop")] {
            panel("nodes")
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                                                       "phoneHub.node." + id + ".", ".new")).firstMatch
            reveal(row)
            row.tap()
            _ = required(app.webViews.staticTexts[title + " fixture chat"].firstMatch)
            shot("route-" + title)
            required(app.tabBars.buttons["Agents"]).tap()
        }
        panel("attention")
        for text in ["Work result", "Home result", "Laptop result"] {
            let row = app.staticTexts[text].firstMatch
            reveal(row)
        }
        shot("03-source-qualified-attention")
        panel("sessions")
        for text in ["Work result", "Home result", "Laptop result"] {
            let row = app.staticTexts[text].firstMatch
            reveal(row)
        }
        let inputSession = app.buttons["phoneHub.session." + work + ".shared.active-shared"]
        reveal(inputSession, upwards: false)
        XCTAssertEqual(inputSession.value as? String, "Input required", "Sessions mark pending input")
        let unseenSession = app.buttons["phoneHub.session." + work + ".shared.session-shared"]
        reveal(unseenSession)
        XCTAssertEqual(unseenSession.value as? String, "Unseen", "Sessions mark unseen results")
        shot("04-source-qualified-sessions")
        app.terminate()
        launch(reset: false)
        openConnections()
        for source in [work, home, direct] {
            XCTAssertTrue(app.descendants(matching: .any)["phoneHub.source." + source].firstMatch.exists,
                          "Connection identity must survive relaunch")
        }
        shot("05-connections-survive-process-relaunch")
    }

    @MainActor
    func testSessionSearchFansOutToEveryAgentAndSorts() throws {
        continueAfterFailure = false
        launch(reset: true, seed: ["work", "home", "direct"])
        let work = id("work"), home = id("home"), direct = id("direct")
        panel("sessions")
        // The list sorts by recent activity by default.
        _ = required(app.buttons["phoneHub.session." + work + ".shared.session-shared"])
        shot("06-sessions-sort-and-search")
        let field = required(app.textFields["phoneHub.sessionSearch"])
        field.tap()
        field.typeText("relay")
        // Typing only filters loaded sessions; asking the agents is explicit.
        _ = required(app.buttons["phoneHub.sessionSearch.agents"])
        XCTAssertFalse(app.buttons["phoneHub.session." + work + ".shared.search-11"].exists)
        shot("07a-session-search-local-first")
        field.typeText("\n")
        // Older matches come from each agent, beyond the dashboard's recent window.
        for row in [work + ".shared", home + ".shared", direct + ".direct-node"] {
            let hit = app.buttons["phoneHub.session." + row + ".search-11"]
            reveal(hit, upwards: false)
        }
        let workHit = app.buttons["phoneHub.session." + work + ".shared.search-11"]
        let running = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Running"), object: workHit)
        XCTAssertEqual(XCTWaiter.wait(for: [running], timeout: 10), .completed,
                       "Run state comes from the follow-up status lookup")
        XCTAssertFalse(app.buttons["phoneHub.sessionSearch.agents"].exists, "The agents were already asked")
        XCTAssertTrue(app.staticTexts["phoneHub.sessionSearch.agent." + work + ".shared"].exists
                      || app.otherElements["phoneHub.sessionSearch.agent." + work + ".shared"].exists,
                      "Relevance groups results by agent")
        shot("07-session-search-fan-out")
        required(app.buttons["phoneHub.sessionSort"]).tap()
        required(app.buttons["Recent activity"]).tap()
        XCTAssertEqual(app.buttons["phoneHub.sessionSort"].value as? String, "Recent activity")
        shot("08-session-search-recent")
        required(app.buttons["phoneHub.sessionSearch.clear"]).tap()
        _ = required(app.buttons["phoneHub.session." + work + ".shared.session-shared"])
        XCTAssertFalse(app.buttons["phoneHub.session." + work + ".shared.search-11"].exists)
    }

    @MainActor
    func testSlowAndUnauthorizedSourcesDoNotBlockHealthySources() async throws {
        continueAfterFailure = false
        launch(reset: true, seed: ["home", "direct", "work", "slow"])
        let work = id("work"), home = id("home"), slow = id("slow")
        try await control("home", "pending-check")
        openConnections()
        shot("connections-list")
        openConnection(slow)
        let slowRetry = app.buttons["phoneHub.retry." + slow]
        reveal(slowRetry)
        slowRetry.tap()
        openConnection(home)
        shot("connection-detail")
        let initialHomeRetry = app.buttons["phoneHub.retry." + home]
        reveal(initialHomeRetry, upwards: false)
        initialHomeRetry.tap()
        panel("nodes")
        // A changed wire title excludes stale cached rows as progress evidence.
        let freshHome = app.staticTexts["Home pending-check refresh"].firstMatch
        reveal(freshHome)
        _ = required(freshHome, timeout: 10)
        openConnection(slow)
        let slowLoading = app.descendants(matching: .any)["phoneHub.nodesLoading." + slow].firstMatch
        reveal(slowLoading, upwards: false)
        XCTAssertTrue(slowLoading.exists, "Slow's native nodes request must still be loading, not timed out")
        // Paired with the passing xcresult, this ordered fixture marker proves
        // the assertion happened before Slow completed, not merely after it began.
        try await control("slow", "pending-asserted")
        shot("06-healthy-sources-visible-during-real-pending-request")
        try await control("work", "unauthorized")
        openConnection(work)
        let retry = app.buttons["phoneHub.retry." + work]
        reveal(retry, upwards: false)
        retry.tap()
        _ = required(app.buttons["phoneHub.signIn." + work], timeout: 15)
        shot("connection-detail-needs-sign-in")
        openConnection(home)
        let homeRetry = app.buttons["phoneHub.retry." + home]
        reveal(homeRetry)
        homeRetry.tap()
        panel("nodes")
        let homeNode = app.buttons["phoneHub.node." + home + ".shared"]
        reveal(homeNode)
        XCTAssertFalse(app.buttons["phoneHub.node." + work + ".shared"].exists)
        shot("07-one-source-auth-failure-isolated")
        // The signed-out source is called out on the home page with a direct
        // sign-in, not left behind Settings › Connections.
        let signIn = required(app.buttons["phoneHub.issue.action." + work], timeout: 10)
        XCTAssertEqual(signIn.label, "Sign In Work Hub")
        XCTAssertFalse(app.buttons["phoneHub.issue.action." + home].exists, "Healthy sources raise no issue")
        shot("08-home-connection-issue")
        signIn.tap()
        _ = required(app.staticTexts["Sign in to Hub"])
        shot("09-home-issue-sign-in")
        required(app.buttons["phoneHub.details.close"]).tap()
        _ = required(app.buttons["phoneHub.issue.action." + work])
    }

    // MARK: Agent page

    @MainActor
    private func openAgentPage(_ source: String) {
        let row = required(app.buttons["phoneHub.node." + source + ".shared"])
        reveal(row)
        row.tap()
        _ = required(app.descendants(matching: .any)["phoneHub.agent"].firstMatch)
    }

    @MainActor
    private func agentRow(_ session: String) -> XCUIElement {
        app.buttons["phoneHub.agent.session." + session]
    }

    /// Swipes the lazily loaded list until `element` exists (paging as it goes).
    @MainActor
    private func scroll(to element: XCUIElement, limit: Int = 40, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<limit {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        _ = required(element, timeout: 5, file: file, line: line)
    }

    @MainActor
    func testAgentPageShowsPinsThenHistoryAndLoadsEveryPage() throws {
        continueAfterFailure = false
        launch(reset: true, seed: ["home"])
        let home = id("home")
        XCTAssertTrue(required(app.buttons["phoneHub.node." + home + ".shared.new"]).isHittable,
                      "A new conversation stays one tap away on the agent row")
        shot("09-agent-row-new-conversation")
        openAgentPage(home)
        _ = required(app.buttons["phoneHub.agent.new"])
        // Pins lead in their saved order, then history by activity.
        let pins = ["session-10", "session-3", "session-25"].map(agentRow)
        for pin in pins { _ = required(pin) }
        let input = required(agentRow("active-shared"))
        XCTAssertLessThan(pins[0].frame.minY, pins[1].frame.minY)
        XCTAssertLessThan(pins[1].frame.minY, pins[2].frame.minY)
        XCTAssertLessThan(pins[2].frame.minY, input.frame.minY)
        let needsInput = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "Needs input"), object: input)
        XCTAssertEqual(XCTWaiter.wait(for: [needsInput], timeout: 10), .completed, "Run state comes from the polled dashboard")
        XCTAssertTrue((agentRow("session-shared").value as? String ?? "").contains("Unseen"))
        shot("10-agent-page")
        // Infinite scroll: all 75 conversations arrive, 30 at a time.
        scroll(to: agentRow("session-75"))
        let end = app.descendants(matching: .any)["phoneHub.agent.end"].firstMatch
        scroll(to: end, limit: 6)
        XCTAssertTrue(end.label.contains("75 conversations"), end.label)
        shot("11-agent-page-end")
    }

    @MainActor
    func testAgentPagePinsRetriesAndKeepsItsPlaceAcrossChat() async throws {
        continueAfterFailure = false
        launch(reset: true, seed: ["home"])
        let home = id("home")
        openAgentPage(home)
        // Swipe right to pin: the conversation joins the end of Pinned at once.
        let webrtc = agentRow("session-4")
        scroll(to: webrtc)
        webrtc.swipeRight()
        required(app.buttons["Pin"].firstMatch).tap()
        for _ in 0..<3 { app.swipeDown() }
        let moved = required(agentRow("session-4"))
        let pinned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "Pinned"), object: moved)
        XCTAssertEqual(XCTWaiter.wait(for: [pinned], timeout: 10), .completed)
        XCTAssertLessThan(required(agentRow("session-25")).frame.minY, moved.frame.minY, "A new pin goes after the existing ones")
        shot("12-agent-page-pinned")
        // A page that fails explains itself and retries in place.
        try await control("home", "sessions-page-error")
        let retry = app.buttons["phoneHub.agent.retry"]
        scroll(to: retry)
        shot("13-agent-page-retry")
        retry.tap()
        scroll(to: agentRow("session-45"))
        // Chat round trip: the page, scroll position and New conversation remain.
        agentRow("session-45").tap()
        _ = required(app.webViews.staticTexts["Home fixture chat"])
        required(app.tabBars.buttons["Agents"]).tap()
        XCTAssertTrue(required(agentRow("session-45")).isHittable, "Returning to Agents keeps the agent page where it was")
        let compose = required(app.buttons["phoneHub.agent.newToolbar"])
        shot("14-agent-page-after-chat")
        compose.tap()
        _ = required(app.webViews.staticTexts["Home fixture chat"])
    }
}
