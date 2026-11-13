import ComputerUseCore
import Foundation
import XCTest
@testable import ComputerUseSystem

// Files and AgentSession only: no app, UI, AX or helper-server effects.
final class InstructionsOwnershipTests: XCTestCase {
    func testConcurrentReadersClaimOnePrefixWithoutHoldingAgentDuringDirectoryLookup() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let agent = AgentSession(key: "agent")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let prefixes = ContextBox<[String]>([])
        let notes = Instructions(stateDirectory: {
            entered.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return folder
        })
        let group = DispatchGroup()
        for bundle in ["com.tinyspeck.slackmacgap", "COM.TINYSPECK.SLACKMACGAP"] {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                if let prefix = notes.prefix(agent: agent, bundleID: bundle) {
                    prefixes.withValue { $0.append(prefix) }
                }
            }
        }
        let first = entered.wait(timeout: .now() + 5)
        let second = entered.wait(timeout: .now() + 5)
        // Updating session state must not wait behind either directory callback.
        let probe = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { agent.instructed = ["already-seen"]; probe.signal() }
        let responsive = probe.wait(timeout: .now() + 5)
        release.signal(); release.signal()
        let finished = group.wait(timeout: .now() + 5)
        XCTAssertEqual(first, .success); XCTAssertEqual(second, .success)
        XCTAssertEqual(responsive, .success); XCTAssertEqual(finished, .success)
        XCTAssertEqual(prefixes.value.count, 1)
        XCTAssertTrue(prefixes.value.first?.contains("## Slack") == true)
        XCTAssertEqual(agent.instructed, ["already-seen", "com.tinyspeck.slackmacgap"])
    }

    func testDirectoryCallbackClaimIsNotPrintedTwice() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let agent = AgentSession(key: "agent")
        let bundle = "com.spotify.client"
        let notes = Instructions(stateDirectory: {
            _ = agent.withState { agent.instructed.insert(bundle) }
            return folder
        })
        XCTAssertNil(notes.prefix(agent: agent, bundleID: bundle))
        XCTAssertEqual(agent.instructed, [bundle])
        // A different agent still receives the same configured note.
        let other = AgentSession(key: "other")
        let independent = Instructions(stateDirectory: { folder })
        XCTAssertTrue(independent.prefix(agent: other, bundleID: bundle)?.contains("## Spotify") == true)
    }
}
