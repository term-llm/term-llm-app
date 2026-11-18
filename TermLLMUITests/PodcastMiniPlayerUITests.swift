import XCTest
import UIKit

/// Real phone tab shell + AVPlayer, with local silent audio and no HTTP server.
/// This is UI/playhead coverage, not proof of audible or physical-device playback.
final class PodcastMiniPlayerUITests: XCTestCase {
    private let episodeTitle = "Episode 212: The long tail of caches and distributed systems"
    private var app: XCUIApplication!

    @MainActor
    private func required(_ element: XCUIElement, file: StaticString = #filePath,
                          line: UInt = #line) -> XCUIElement {
        waitFor("Control must be visible and tappable", file: file, line: line) {
            element.exists && element.isHittable
        }
        return element
    }

    @MainActor
    private func waitFor(_ message: String, timeout: TimeInterval = 5,
                         file: StaticString = #filePath, line: UInt = #line,
                         condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       message, file: file, line: line)
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Inspect real rendered pixels, not an accessibility label or cache hit.
    /// Normalize only the leading <=56 pt to a bounded bitmap, independent of
    /// Retina scale. Broad center-color areas tolerate resampling/JPEG edges;
    /// the missing-artwork symbol cannot supply both amber and gold patches.
    private func containsFixtureCover(_ screenshot: XCUIScreenshot, buttonWidth: CGFloat) -> Bool {
        guard buttonWidth > 0, let image = screenshot.image.cgImage,
              let leading = image.cropping(to: CGRect(
                x: 0, y: 0, width: ceil(CGFloat(image.width) * min(56, buttonWidth / 2) / buttonWidth),
                height: CGFloat(image.height))) else { return false }
        let size = 56
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: size, height: size,
                                          bitsPerComponent: 8, bytesPerRow: size * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                                            | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(leading, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard rendered else { return false }
        // These are the illustration's solid center fills, not exact edge
        // pixels. Limit the scan to the middle half of the button's height.
        return [(14, 25, 46), (232, 153, 45), (250, 211, 112)].allSatisfy { r, g, b in
            var matches = 0
            for y in (size / 4)..<(size * 3 / 4) {
                for x in 0..<size {
                    let offset = (y * size + x) * 4
                    if abs(Int(pixels[offset]) - r) <= 24,
                       abs(Int(pixels[offset + 1]) - g) <= 24,
                       abs(Int(pixels[offset + 2]) - b) <= 24 { matches += 1 }
                }
            }
            return matches >= 20
        }
    }

    @MainActor
    private func assertCompactCover(in button: XCUIElement) {
        var screenshot: XCUIScreenshot?
        waitFor("Compact miniPlayerOpen must render the local navy/amber/gold cover") {
            let sample = button.screenshot()
            screenshot = sample
            return self.containsFixtureCover(sample, buttonWidth: button.frame.width)
        }
        if let screenshot {
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "podcast-compact-real-cover-pixel-proof"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func seconds(_ time: String) -> Int? {
        let components = time.split(separator: ":").compactMap { Int($0) }
        guard (2...3).contains(components.count) else { return nil }
        return components.reduce(0) { $0 * 60 + $1 }
    }

    private func remainingSeconds(_ label: String) -> Int? {
        guard let range = label.range(of: #"\d+(?::\d{2}){1,2} left"#, options: .regularExpression) else { return nil }
        return seconds(String(label[range].dropLast(" left".count)))
    }

    @MainActor
    func testCompactPodcastControlsExpandAndHideWithoutStopping() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["TERMLLM_PHONE_HUB_FIXTURE_URL"] = "http://localhost:8767/"
        app.launchEnvironment["TERMLLM_PHONE_HUB_FIXTURE_RESET"] = "1"
        app.launchEnvironment["TERMLLM_PHONE_HUB_FIXTURE_SEED"] = ""
        app.launchEnvironment["TERMLLM_LISTEN_SHELF_FIXTURE"] = "1"
        app.launch()
        defer { app.terminate() }
        try XCTSkipIf(app.windows.firstMatch.frame.width >= 600, "Run this compact-shelf regression on an iPhone")
        _ = required(app.staticTexts["phoneHub.fixtureBanner"])
        for tab in ["Agents", "Chat", "Music", "Podcasts"] {
            _ = required(app.tabBars.buttons[tab])
        }

        let shelf = app.descendants(matching: .any)["miniPlayer"].firstMatch
        let toggle = app.buttons["miniPlayerPlayPause"]
        let title = app.buttons["miniPlayerOpen"]
        let close = app.buttons["miniPlayerClose"]
        waitFor("The local episode should start playing") { toggle.exists && toggle.label == "Pause" }
        _ = required(toggle)
        XCTAssertEqual(required(title).label, "Now playing: " + episodeTitle)
        assertCompactCover(in: title)
        XCTAssertEqual(required(close).label, "Hide Podcast player")
        XCTAssertTrue(app.windows.firstMatch.frame.contains(close.frame), "× must fit inside the phone window")
        // Custom accessibility skip actions may remain; only inline buttons
        // must be absent from the visible compact surface.
        for label in ["Back 15 seconds", "Forward 30 seconds", "Previous", "Next"] {
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == %@", label))
                .allElementsBoundByIndex.contains(where: \.isHittable), "Unexpected inline \(label)")
        }
        capture("podcast-compact-play-pause-and-visible-close")
        toggle.tap()
        waitFor("Compact Pause should become Play") { toggle.label == "Play" }
        required(toggle).tap()
        waitFor("Compact Play should become Pause") { toggle.label == "Pause" }

        required(title).tap()
        _ = required(app.navigationBars["Now Playing"])
        let expanded = app.descendants(matching: .any)["listenExpandedPlayer"].firstMatch
        let back = required(expanded.buttons["Back 15 seconds"])
        let forward = required(expanded.buttons["Forward 30 seconds"])
        required(expanded.buttons["Pause"]).tap()
        _ = required(expanded.buttons["Play"])
        let position = expanded.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Position'")).firstMatch
        let paused = try XCTUnwrap((position.value as? String)?.components(separatedBy: " of ").first.flatMap(seconds))
        forward.tap()
        waitFor("Expanded forward skip should seek 30 seconds") {
            (position.value as? String)?.components(separatedBy: " of ").first.flatMap(self.seconds) == paused + 30
        }
        back.tap()
        waitFor("Expanded back skip should seek 15 seconds") {
            (position.value as? String)?.components(separatedBy: " of ").first.flatMap(self.seconds) == paused + 15
        }
        required(expanded.buttons["Play"]).tap()
        _ = required(expanded.buttons["Pause"])
        capture("podcast-expanded-now-playing-with-skips")
        required(app.buttons["listenPlayerClose"]).tap()
        _ = required(close)
        waitFor("Dismissing Now Playing must leave playback running") { toggle.label == "Pause" }
        close.tap()
        waitFor("× must hide the shelf") { !shelf.exists && !close.exists }

        // The library exposes saved time-left, not live player status. A
        // background transition flushes the current position through the real
        // app lifecycle observer without starting/resuming playback. Establish
        // the baseline AFTER hiding, so a stop's final save cannot pass this.
        XCUIDevice.shared.press(.home)
        app.activate()
        required(app.tabBars.buttons["Podcasts"]).tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", episodeTitle)).firstMatch
        _ = required(row)
        let before = try XCTUnwrap(remainingSeconds(row.label), "Expected saved time-left in the library row")
        for tab in ["Chat", "Agents", "Podcasts"] {
            required(app.tabBars.buttons[tab]).tap()
            XCTAssertFalse(shelf.exists || close.exists, "Tab remounts must not resurrect a dismissed shelf")
        }
        // Observe several real playhead ticks, not just the dismissal animation.
        let reappeared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in shelf.exists || close.exists }, object: nil)
        reappeared.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [reappeared], timeout: 3), .completed,
                       "The shelf must stay hidden across playback ticks")
        XCUIDevice.shared.press(.home)
        app.activate()
        waitFor("Hidden playback must keep advancing without a new Play action") {
            guard row.exists, let after = self.remainingSeconds(row.label) else { return false }
            return after < before
        }
        XCTAssertFalse(shelf.exists || close.exists)
        let evidence = XCTAttachment(string: "Saved seconds remaining after hide: \(before) → \(row.label). No Play action occurred between samples.")
        evidence.name = "hidden-podcast-playhead-advanced"
        evidence.lifetime = .keepAlways
        add(evidence)
        capture("podcast-hidden-still-advancing-after-tabs-and-ticks")
    }
}
