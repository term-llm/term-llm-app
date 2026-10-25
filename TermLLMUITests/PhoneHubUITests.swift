import XCTest

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
        let inSheet = app.buttons["settings.done"].exists || app.navigationBars["Connections"].exists
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
        if app.navigationBars["Connections"].exists { return }
        if !app.buttons["settings.done"].exists {
            required(app.buttons["phoneHub.settings"]).tap()
        }
        required(app.buttons["settings.connections"]).tap()
        _ = required(app.navigationBars["Connections"])
    }

    @MainActor
    private func closeConnections() {
        let connectionsBar = app.navigationBars["Connections"]
        if connectionsBar.exists {
            connectionsBar.buttons["Settings"].tap()
            _ = required(app.buttons["settings.done"])
        }
        if app.buttons["settings.done"].exists {
            app.buttons["settings.done"].tap()
        }
        _ = required(app.staticTexts["phoneHub.home"])
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
        required(app.buttons["phoneHub.node." + work + ".shared"]).tap()
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

    @MainActor
    func testRemovingCurrentConnectionDoesNotRetargetChatToAnotherAgent() throws {
        continueAfterFailure = false
        launch(reset: true, seed: ["work", "home"])
        let work = id("work")
        required(app.buttons["phoneHub.node." + work + ".shared"]).tap()
        _ = required(app.webViews.staticTexts["Work fixture chat"])
        required(app.tabBars.buttons["Agents"]).tap()
        openConnections()
        required(app.buttons["phoneHub.remove." + work]).tap()
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
        required(app.buttons["phoneHub.addConnection"]).tap()
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
        workNode.tap()
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
        required(app.buttons["phoneHub.node." + work + ".shared"]).tap()
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
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "phoneHub.node." + id + ".")).firstMatch
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
        let slowRetry = app.buttons["phoneHub.retry." + slow]
        reveal(slowRetry)
        slowRetry.tap()
        let initialHomeRetry = app.buttons["phoneHub.retry." + home]
        reveal(initialHomeRetry, upwards: false)
        initialHomeRetry.tap()
        panel("nodes")
        // A changed wire title excludes stale cached rows as progress evidence.
        let freshHome = app.staticTexts["Home pending-check refresh"].firstMatch
        reveal(freshHome)
        _ = required(freshHome, timeout: 10)
        openConnections()
        let slowLoading = app.descendants(matching: .any)["phoneHub.nodesLoading." + slow].firstMatch
        reveal(slowLoading, upwards: false)
        XCTAssertTrue(slowLoading.exists, "Slow's native nodes request must still be loading, not timed out")
        // Paired with the passing xcresult, this ordered fixture marker proves
        // the assertion happened before Slow completed, not merely after it began.
        try await control("slow", "pending-asserted")
        shot("06-healthy-sources-visible-during-real-pending-request")
        try await control("work", "unauthorized")
        let retry = app.buttons["phoneHub.retry." + work]
        reveal(retry, upwards: false)
        retry.tap()
        _ = required(app.buttons["phoneHub.signIn." + work], timeout: 15)
        let homeRetry = app.buttons["phoneHub.retry." + home]
        reveal(homeRetry)
        homeRetry.tap()
        panel("nodes")
        let homeNode = app.buttons["phoneHub.node." + home + ".shared"]
        reveal(homeNode)
        XCTAssertFalse(app.buttons["phoneHub.node." + work + ".shared"].exists)
        shot("07-one-source-auth-failure-isolated")
    }
}
