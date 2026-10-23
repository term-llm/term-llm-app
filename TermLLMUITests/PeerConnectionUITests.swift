import XCTest

/// Actual OS pairing URL + native peer approval + upstream WebKit chat.
/// Requires the explicit DEBUG simulator adapter in peer-ci-interface.md.
final class PeerConnectionUITests: XCTestCase {
    private var app: XCUIApplication!

    @MainActor
    private func required(_ element: XCUIElement, timeout: TimeInterval = 60) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Required real peer UI element missing")
        return element
    }

    @MainActor
    private func shot(_ name: String) {
        let label = app.staticTexts["peer.captureLabel"]
        XCTAssertTrue(label.exists)
        XCTAssertTrue(label.label.contains("SCRIPTED PROVIDER"))
        XCTAssertTrue(label.label.contains("REAL TRANSPORT"))
        XCTAssertTrue(label.label.contains("SIMULATOR INSTALL"))
        // The native approval view must never show the secret URI/fragment.
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'ps=' OR label CONTAINS 'cap='")).firstMatch.exists)
        Thread.sleep(forTimeInterval: 1)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name + "-SCRIPTED-PROVIDER-REAL-TRANSPORT"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testPeerConnectionJourney() throws {
        continueAfterFailure = false
        // Path only crosses xcodebuild's environment. Never print configuration,
        // pairing URL, ICE credentials, failed decode objects, or launch env.
        guard let path = ProcessInfo.processInfo.environment["PEER_CAPTURE_CONFIG_PATH"],
              let data = FileManager.default.contents(atPath: path),
              let config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mode = config["mode"] as? String,
              let node = config["node_id"] as? String,
              let prompt = config["prompt"] as? String,
              config["schema_version"] as? Int == 1,
              let json = String(data: data, encoding: .utf8) else {
            XCTFail("Private runtime adapter unavailable")
            return
        }
        app = XCUIApplication()
        app.launchEnvironment["TERMLLM_PEER_CAPTURE_JSON"] = json
        // No fixture/serverURL injection. Native DEBUG launcher opens the supplied
        // link through UIApplication (actual URL handler), without a secret CLI
        // argument or XCTest open(URL) activity.
        app.launch()
        _ = required(app.staticTexts["peer.captureLabel"])
        shot(mode + "-01-native-launch")
        required(app.buttons["peer.capture.openPairLink"]).tap()
        _ = required(app.otherElements["peer.approval"].firstMatch, timeout: 120)
        shot(mode + "-02-real-pairing-approval")
        required(app.buttons["peer.approve"]).tap()
        _ = required(app.staticTexts["peer.connected"], timeout: 120)
        if mode == "relay" {
            let relayLabel = required(app.staticTexts["peer.relayLabel"])
            XCTAssertTrue(relayLabel.label.contains("SELF-HOSTED TURN"))
            XCTAssertTrue(relayLabel.label.contains("NOT CLOUDFLARE"))
        }
        shot(mode + "-03-paired-actual-datachannel")
        required(app.buttons["hub.open"]).tap()
        let nodeButton = app.buttons["hub.node." + node].firstMatch
        for _ in 0..<6 {
            if nodeButton.exists && nodeButton.isHittable { break }
            app.swipeUp()
        }
        _ = required(nodeButton)
        shot(mode + "-04-native-hub-remote-node")
        nodeButton.tap()
        required(app.buttons["New conversation"].firstMatch).tap()
        let composer = app.webViews.textViews["Message"].firstMatch
        _ = required(composer)
        shot(mode + "-05-real-upstream-chat")
        // Native instrumentation samples actual RTC stats before this specific
        // chat request, not before aggregate Hub polling or an invented reply.
        required(app.buttons["peer.capture.beforeChat"]).tap()
        composer.tap()
        composer.typeText(prompt)
        let send = required(app.webViews.buttons["Send message"].firstMatch)
        XCTAssertTrue(send.isEnabled)
        send.tap()
        // Brand-new conversation: upstream Copy response appears only on a
        // completed assistant turn. No provider nonce echo is assumed.
        _ = required(app.webViews.buttons["Copy response"].firstMatch, timeout: 120)
        XCTAssertFalse(app.webViews.buttons["Stop"].exists)
        shot(mode + "-06-real-completed-scripted-provider-response")
        let returned = Date()
        app.buttons["hub.open"].tap()
        _ = required(app.buttons["hub.node." + node].firstMatch, timeout: 10)
        XCTAssertLessThan(Date().timeIntervalSince(returned), 10)
        shot(mode + "-07-native-hub-return")
        required(app.buttons["peer.diagnostics.export"]).tap()
        _ = required(app.staticTexts["peer.diagnostics.exported"])
        shot(mode + "-08-actual-selected-ice-and-response-evidence-exported")
    }
}
