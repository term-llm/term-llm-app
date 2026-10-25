import XCTest
@testable import TermLLM

@MainActor
final class VoiceShortcutTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "VoiceShortcutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testTargetPersistsAndClears() {
        let defaults = defaults()
        XCTAssertNil(VoiceShortcutTarget.load(from: defaults))
        let target = VoiceShortcutTarget(sourceID: UUID(), nodeID: "jarvis", name: "Jarvis",
                                         path: "/hub/node/jarvis/?new=1")
        VoiceShortcutTarget.save(target, to: defaults)
        XCTAssertEqual(VoiceShortcutTarget.load(from: defaults), target)
        VoiceShortcutTarget.save(nil, to: defaults)
        XCTAssertNil(VoiceShortcutTarget.load(from: defaults))
    }

    func testLaunchRequestsCoalesceUntilFinished() {
        let center = VoiceLaunchCenter()
        XCTAssertNil(center.request)
        center.requestLaunch()
        let first = center.request
        XCTAssertNotNil(first)
        center.requestLaunch()
        XCTAssertEqual(center.request, first)
        center.finish()
        XCTAssertNil(center.request)
        center.requestLaunch()
        XCTAssertNotEqual(center.request, first)
    }

    func testIntentQueuesTheSharedLaunchMechanism() async throws {
        let center = VoiceLaunchCenter.shared
        center.finish()
        defer { center.finish() }
        _ = try await StartLiveConversationIntent().perform()
        XCTAssertNotNil(center.request)
        let request = center.request
        _ = try await StartLiveConversationIntent().perform()
        XCTAssertEqual(center.request, request)
        XCTAssertTrue(StartLiveConversationIntent.openAppWhenRun)
    }
}
