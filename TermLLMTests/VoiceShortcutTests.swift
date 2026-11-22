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

    func testLinkedDevicesAreNeverShortcutTargetsEvenWhenTheyAdvertiseDeviceTools() {
        let linked = HubConnection(id: UUID(), name: "Desk", kind: .directNode,
                                   url: URL(string: "http://localhost:43301/chat/")!, needsKindReview: nil,
                                   linkedDevicesHostKey: LinkedDevicesBase64URL.encode(Data(repeating: 1, count: 32)))
        let direct = HubConnection(id: UUID(), name: "Node", kind: .directNode,
                                   url: URL(string: "https://node.example/")!)
        let hub = HubConnection(id: UUID(), name: "Hub", kind: .hub, url: URL(string: "https://hub.example/")!)
        XCTAssertFalse(VoiceShortcutTarget.supports(linked))
        XCTAssertEqual(VoiceShortcutTarget.unsupportedReason(for: linked),
                       "Linked devices can’t be voice shortcut targets. Start Live from the linked chat, or choose another agent in Settings.")
        for connection in [direct, hub] {
            XCTAssertTrue(VoiceShortcutTarget.supports(connection))
            XCTAssertNil(VoiceShortcutTarget.unsupportedReason(for: connection))
        }
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
