import SwiftUI
import WebKit
import XCTest
@testable import TermLLM

// Menu/keyboard routing is native policy, independent of server or WebKit timing.
@MainActor
final class DesktopCommandTests: XCTestCase {
    private func policy(tab: AppTab = .agents, enabled: Bool = true, sources: Bool = true,
                        chat: Bool = true, parked: Bool = false, back: Bool = true, zoom: Bool = true) -> DesktopCommandPolicy {
        .init(tab: tab, enabled: enabled, hasSources: sources, chatAvailable: chat,
              chatParked: parked, canGoBack: back, canZoom: zoom)
    }

    func testTabShortcutsOnlySelectExistingDestinations() {
        XCTAssertEqual(DesktopCommand.tabs.compactMap(\.tab), AppTab.allCases)
        XCTAssertEqual(DesktopCommand.tabs.map(\.input), ["1", "2", "3", "4"])
        XCTAssertEqual(DesktopCommand.settings.input, ",")
        XCTAssertEqual(DesktopCommand.refresh.input, "r")
        XCTAssertEqual(DesktopCommand.back.input, "[")
        XCTAssertEqual(DesktopCommand.zoom.map(\.input), ["+", "-", "0"])
        XCTAssertEqual(DesktopCommand.zoom.map(\.title), ["Zoom In", "Zoom Out", "Actual Size"])
        XCTAssertEqual(DesktopCommand.allCases.count, 10, "No unsafe new-conversation command")
    }

    func testRefreshNeverTargetsHiddenRetainedChat() {
        XCTAssertEqual(policy(tab: .agents).refresh, .agents)
        XCTAssertNil(policy(tab: .agents, sources: false).refresh)
        for tab: AppTab in [.music, .podcasts] {
            let state = policy(tab: tab)
            XCTAssertNil(state.refresh)
            XCTAssertFalse(state.allows(.refresh))
            XCTAssertFalse(state.allows(.back))
        }
        XCTAssertEqual(policy(tab: .chat).refresh, .chat)
        XCTAssertEqual(policy(tab: .chat, parked: true).refresh, .reopenChat)
        XCTAssertNil(policy(tab: .chat, chat: false).refresh)
    }

    func testBackRequiresVisibleLiveChatWithHistory() {
        for tab in AppTab.allCases {
            XCTAssertEqual(policy(tab: tab).allows(.back), tab == .chat)
        }
        XCTAssertFalse(policy(tab: .chat, chat: false).allows(.back))
        XCTAssertFalse(policy(tab: .chat, parked: true).allows(.back))
        XCTAssertFalse(policy(tab: .chat, back: false).allows(.back))
        XCTAssertTrue(policy(tab: .chat).allows(.back))
    }

    func testInactiveOrObscuredContentRejectsEveryCommand() {
        for tab in AppTab.allCases {
            let state = policy(tab: tab, enabled: false)
            XCTAssertNil(state.refresh)
            for command in DesktopCommand.allCases { XCTAssertFalse(state.allows(command)) }
        }
    }

    func testZoomIsLimitedToVisibleLiveChatOnMac() {
        for command in DesktopCommand.zoom {
            for tab in AppTab.allCases {
                XCTAssertEqual(policy(tab: tab).allows(command), tab == .chat)
            }
            XCTAssertFalse(policy(tab: .chat, chat: false).allows(command))
            XCTAssertFalse(policy(tab: .chat, parked: true).allows(command))
            XCTAssertFalse(policy(tab: .chat, zoom: false).allows(command))
        }
    }

    func testZoomDefaultsAndClampsInvalidOrOutOfRangePreferences() {
        XCTAssertEqual(DesktopChatAppearance.defaultZoom, 1.0)
        XCTAssertEqual(DesktopChatAppearance.clamped(0.5), 0.75)
        XCTAssertEqual(DesktopChatAppearance.clamped(3), 2)
        XCTAssertEqual(DesktopChatAppearance.clamped(.nan), 1.0)
        XCTAssertEqual(DesktopChatAppearance.clamped(.infinity), 1.0)
        XCTAssertEqual(DesktopChatAppearance.adjusted(1.25, by: 0.25), 1.5)
        XCTAssertEqual(DesktopChatAppearance.adjusted(0.75, by: -0.25), 0.75)
        XCTAssertEqual(DesktopChatAppearance.adjusted(2, by: 0.25), 2)
    }


}
