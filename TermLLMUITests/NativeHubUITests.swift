import XCTest

/// Real SwiftUI app + real loopback HTTP; synthetic data is visibly disclosed.
/// No serverURL launch override: first-run onboarding is part of the journey.
final class NativeHubUITests: XCTestCase {
    private var app: XCUIApplication!

    @MainActor
    private func launchFixtureApp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["TERMLLM_NATIVE_HUB_FIXTURE_URL"] = "http://localhost:8766/"
        app.launch()
    }

    @MainActor
    @discardableResult
    private func required(_ element: XCUIElement, timeout: TimeInterval = 15,
                          file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing \(element)", file: file, line: line)
        return element
    }

    @MainActor
    private func capture(_ name: String) {
        XCTAssertTrue(app.staticTexts["hub.fixtureBanner"].exists, "Every screen must visibly disclose fixture mode")
        // Readable continuous video; assertions, not these waits, decide pass/fail.
        Thread.sleep(forTimeInterval: 1)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name + "-DEMO-FIXTURE-LOCAL"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, upwards: Bool = true,
                        file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<6 {
            if element.exists && element.isHittable { return }
            if upwards { app.swipeUp() } else { app.swipeDown() }
        }
        XCTAssertTrue(element.exists && element.isHittable, "Cannot reveal \(element)", file: file, line: line)
    }

    private var selectedPanel = "hub.nodes"

    @MainActor
    private func selectPanel(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let panels = ["hub.nodes", "hub.attention", "hub.delegations", "hub.management", "hub.security"]
        guard let targetIndex = panels.firstIndex(of: identifier) else {
            XCTFail("Unknown native Hub panel: \(identifier)", file: file, line: line)
            return
        }
        let button = required(app.buttons[identifier].firstMatch, file: file, line: line)
        let strip = required(app.scrollViews.containing(.button, identifier: identifier).firstMatch,
                             file: file, line: line)
        for attempt in 0...panels.count {
            let viewport = strip.frame.intersection(app.frame)
            let frame = button.frame
            let validFrame = !frame.isEmpty && !frame.isInfinite &&
                frame.minX.isFinite && frame.minY.isFinite && frame.maxX.isFinite && frame.maxY.isFinite
            guard !viewport.isEmpty && !viewport.isNull else {
                XCTFail("Native Hub panel strip is not onscreen", file: file, line: line)
                return
            }
            // Offscreen SwiftUI buttons can throw an XCTest activation-point
            // error merely reading isHittable. Reveal the real element first.
            if validFrame && viewport.contains(frame) {
                guard button.isHittable else {
                    XCTFail("Visible native panel is not hittable: \(identifier)", file: file, line: line)
                    return
                }
                button.tap()
                selectedPanel = identifier
                return
            }
            guard attempt < panels.count else { break }
            let earlier = validFrame ? frame.minX < viewport.minX :
                targetIndex < (panels.firstIndex(of: selectedPanel) ?? 0)
            // Swipe the actual ancestor ScrollView, never offscreen coordinates
            // or the vertically scrolling page. This also returns to Nodes
            // after Security has scrolled it off the left edge.
            if earlier { strip.swipeRight() } else { strip.swipeLeft() }
        }
        XCTFail("Could not reveal native panel after bounded horizontal swipes: \(identifier)",
                file: file, line: line)
    }

    @MainActor
    func testNativeHubJourney() throws {
        launchFixtureApp()
        let address = required(app.textFields["serverAddress"])
        capture("01-first-run-connect")
        address.tap()
        address.typeText("http://localhost:8766/")
        capture("02-loopback-address-entered")
        if app.buttons["serverConnect"].isHittable {
            app.buttons["serverConnect"].tap()
        } else {
            address.typeText("\n") // Go invokes the same native connect handler.
        }
        required(app.buttons["hub.open"])
        required(app.buttons["hub.node.dev"])
        let ready = app.buttons["hub.session.open.dev.demo-ready"].firstMatch
        reveal(ready)
        XCTAssertTrue(ready.isEnabled)
        capture("03-native-dashboard-nodes-sessions")

        let offline = app.buttons["hub.node.offline"].firstMatch
        reveal(offline)
        offline.tap()
        // SwiftUI LabeledContent exposes the value as a combined accessibility
        // label (confirmed in the failed run's hierarchy), not a standalone text.
        required(app.staticTexts["Status, disconnected"].firstMatch)
        let offlineNewChat = required(app.buttons["New conversation"].firstMatch)
        XCTAssertFalse(offlineNewChat.isEnabled, "Disconnected nodes must not offer an enabled chat launch")
        capture("04-offline-node-native-details")
        // Standard native back navigation, not a WebKit/browser back action.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        required(app.buttons["hub.attention"])

        selectPanel("hub.attention")
        let needsInput = app.staticTexts["Review the demo patch"].firstMatch
        reveal(needsInput, upwards: false)
        required(needsInput)
        required(app.staticTexts["Demo result ready"].firstMatch)
        capture("05-native-attention")

        selectPanel("hub.delegations")
        required(app.staticTexts["No delegated work yet"].firstMatch)
        capture("06-native-delegations")

        selectPanel("hub.management")
        let registration = app.staticTexts["Node registration is disabled."].firstMatch
        reveal(registration)
        capture("07-native-management-no-registration-token")

        selectPanel("hub.security")
        let credential = app.staticTexts["Demo passkey (not real)"].firstMatch
        reveal(credential, upwards: false)
        required(credential)
        capture("08-native-security-synthetic-session")
        // Read-only inspection. Never invoke destructive/security ceremonies.

        selectPanel("hub.nodes")
        reveal(ready, upwards: false)
        ready.tap()
        required(app.webViews.staticTexts["Demo fixture chat"].firstMatch)
        capture("09-actual-webview-local-chat-html")
        app.buttons["hub.open"].tap()
        required(app.buttons["hub.node.dev"])
        capture("10-native-return-from-chat")

        let stalled = app.buttons["hub.session.open.stalled.demo-stalled"].firstMatch
        reveal(stalled)
        stalled.tap()
        required(app.buttons["hub.open"])
        // Give the actual pending HTTP navigation time to reach the loopback
        // server. The artifact gate also requires its 'stalled' request record.
        Thread.sleep(forTimeInterval: 3)
        capture("11-stalled-http-chat-native-controls-still-available")
        let recoveryStarted = Date()
        app.buttons["hub.open"].tap()
        required(app.buttons["hub.node.dev"], timeout: 8)
        XCTAssertLessThan(Date().timeIntervalSince(recoveryStarted), 8,
                          "Native Hub must return without waiting for the stalled HTTP response")
        app.buttons["hub.refresh"].tap()
        required(app.buttons["hub.session.open.dev.demo-ready"])
        capture("12-native-recovery-and-refresh-while-chat-stalls")
    }
}
