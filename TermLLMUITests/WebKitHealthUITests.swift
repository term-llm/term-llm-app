import XCTest

/// Opt-in journey against the live demo web UI (network): the real frontend
/// with the injected probe, the diagnostics screen, and a manual pause that
/// closes the page and reopens it. Run with
/// `TEST_RUNNER_TERMLLM_WEBKIT_HEALTH_DEMO=1 xcodebuild test … -only-testing:TermLLMUITests/WebKitHealthUITests`
/// on a simulator without saved connections.
final class WebKitHealthUITests: XCTestCase {
    private var app: XCUIApplication!

    @MainActor
    private func required(_ element: XCUIElement, timeout: TimeInterval = 30,
                          file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let found = element.exists || element.waitForExistence(timeout: timeout)
        if !found {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "webkit-health-missing-element-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            shot("failure")
        }
        XCTAssertTrue(found, "Required element missing", file: file, line: line)
        return element
    }

    @MainActor
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "webkit-health-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func reveal(_ element: XCUIElement) {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
    }

    @MainActor
    func testDiagnosticsWatchPauseAndReopenTheDemoPage() throws {
        guard ProcessInfo.processInfo.environment["TERMLLM_WEBKIT_HEALTH_DEMO"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_TERMLLM_WEBKIT_HEALTH_DEMO=1 to run against the live demo")
        }
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()

        // The demo opens straight into Chat; let the probe report a few times.
        required(app.buttons["phoneHub.demo"]).tap()
        _ = required(app.webViews.firstMatch, timeout: 60)
        sleep(12)
        shot("1-chat")

        required(app.tabBars.buttons["Agents"]).tap()
        required(app.buttons["phoneHub.settings"]).tap()
        let row = app.buttons["settings.webKitHealth"]
        reveal(row)
        required(row).tap()
        let cost = required(app.descendants(matching: .any)["webKitHealth.cost"])
        XCTAssertTrue(app.descendants(matching: .any)["webKitHealth.temperature"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["webKitHealth.chatStatus"].exists)
        sleep(6)
        shot("2-diagnostics")
        let costText = [cost.label, cost.value as? String ?? ""].joined(separator: " ")
        XCTAssertFalse(costText.contains("page n/a"), "the probe reported its own cost: \(costText)")
        XCTAssertFalse(costText.contains("app n/a"), costText)

        // Pausing closes the page; Chat then offers to reload it.
        let pause = app.buttons["webKitHealth.pause"]
        reveal(pause)
        required(pause).tap()
        let reload = required(app.buttons["webKitHealth.reload"], timeout: 10)
        sleep(6)
        shot("3-paused")
        XCTAssertTrue(reload.exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        required(app.buttons["settings.done"]).tap()
        required(app.tabBars.buttons["Chat"]).tap()
        let reopen = required(app.buttons["chat.reloadParked"], timeout: 10)
        XCTAssertFalse(app.webViews.firstMatch.exists, "the paused page's web view is closed")
        shot("4-chat-paused")
        reopen.tap()
        _ = required(app.webViews.firstMatch, timeout: 60)
        sleep(3)
        shot("5-chat-reopened")
    }
}
