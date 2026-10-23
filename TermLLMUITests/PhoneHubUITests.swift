import XCTest

/// Real native UI + loopback HTTP protocol fixtures, not live agents or auth.
final class PhoneHubUITests: XCTestCase {
    private var app: XCUIApplication!
    private let fixture = "http://localhost:8767"

    @MainActor
    private func required(_ element: XCUIElement, timeout: TimeInterval = 30,
                          file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let found = element.waitForExistence(timeout: timeout)
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

    @MainActor
    private func launch(reset: Bool) {
        app = XCUIApplication()
        app.launchEnvironment["TERMLLM_PHONE_HUB_FIXTURE_URL"] = fixture + "/"
        app.launchEnvironment["TERMLLM_PHONE_HUB_FIXTURE_RESET"] = reset ? "1" : "0"
        app.launch()
        _ = required(app.staticTexts["phoneHub.fixtureBanner"])
    }

    @MainActor
    private func reveal(_ element: XCUIElement, upwards: Bool = true,
                        file: StaticString = #filePath, line: UInt = #line) {
        for direction in [upwards, !upwards] {
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

    @MainActor
    private func addConnection(_ name: String, path: String, direct: Bool = false) {
        let add = app.buttons["phoneHub.addConnection"]
        reveal(add, upwards: false)
        add.tap()
        let nameField = required(app.textFields["phoneHub.connection.name"])
        nameField.tap()
        nameField.typeText(name)
        let address = required(app.textFields["phoneHub.connection.url"])
        address.tap()
        address.typeText(fixture + path)
        let kind = direct ? "Direct Node" : "Hub"
        let segments = app.segmentedControls["phoneHub.connection.kind"]
        if segments.exists {
            required(segments.buttons[kind]).tap()
        } else {
            required(app.buttons["phoneHub.connection.kind"]).tap()
            required(app.buttons[kind].firstMatch).tap()
        }
        required(app.buttons["phoneHub.connection.save"]).tap()
        _ = required(app.staticTexts[name].firstMatch)
    }

    @MainActor
    private func sourceID(_ name: String) -> String {
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
        let button = required(app.buttons["phoneHub." + name])
        reveal(button)
        button.tap()
    }

    private func control(_ source: String, _ state: String) async throws {
        var request = URLRequest(url: URL(string: fixture + "/__control/" + source + "/" + state)!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    @MainActor
    func testSavedConnectionsAndUnifiedViews() throws {
        continueAfterFailure = false
        launch(reset: true)
        shot("01-empty-local-home")
        addConnection("Work Hub", path: "/work/")
        addConnection("Home Hub", path: "/home/")
        addConnection("Laptop", path: "/direct/", direct: true)
        let work = sourceID("Work Hub"), home = sourceID("Home Hub"), direct = sourceID("Laptop")
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
            required(app.buttons["phoneHub.returnHome"]).tap()
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
        shot("04-source-qualified-sessions")
        app.terminate()
        launch(reset: false)
        XCTAssertEqual(sourceID("Work Hub"), work)
        XCTAssertEqual(sourceID("Home Hub"), home)
        XCTAssertEqual(sourceID("Laptop"), direct)
        shot("05-connections-survive-process-relaunch")
    }

    @MainActor
    func testSlowAndUnauthorizedSourcesDoNotBlockHealthySources() async throws {
        continueAfterFailure = false
        launch(reset: true)
        try await control("work", "healthy")
        addConnection("Home Hub", path: "/home/")
        addConnection("Laptop", path: "/direct/", direct: true)
        addConnection("Work Hub", path: "/work/")
        let work = sourceID("Work Hub"), home = sourceID("Home Hub")
        // Start Slow last: typing the other saved connections must not consume
        // its real native request timeout before the concurrency assertion.
        addConnection("Slow Hub", path: "/slow/")
        let slow = sourceID("Slow Hub")
        try await control("home", "pending-check")
        let initialHomeRetry = app.buttons["phoneHub.retry." + home]
        reveal(initialHomeRetry, upwards: false)
        initialHomeRetry.tap()
        panel("nodes")
        // A changed wire title excludes stale cached rows as progress evidence.
        let freshHome = app.staticTexts["Home pending-check refresh"].firstMatch
        reveal(freshHome)
        _ = required(freshHome, timeout: 10)
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
