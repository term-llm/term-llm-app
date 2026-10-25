import AppIntents
import Foundation
import SwiftUI

/// The agent the voice shortcut opens. Stores the agent's new-conversation
/// path so a cold launch from the Action Button needs no network round trip.
struct VoiceShortcutTarget: Codable, Equatable {
    static let storageKey = "voiceShortcut.target"

    let sourceID: UUID
    let nodeID: String
    let name: String
    let path: String

    var key: String { "\(sourceID.uuidString)|\(nodeID)" }

    static func load(from defaults: UserDefaults) -> VoiceShortcutTarget? {
        defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    static func save(_ target: VoiceShortcutTarget?, to defaults: UserDefaults) {
        if let target, let data = try? JSONEncoder().encode(target) {
            defaults.set(data, forKey: storageKey)
        } else {
            defaults.removeObject(forKey: storageKey)
        }
    }
}

@MainActor
final class VoiceLaunchCenter: ObservableObject {
    static let shared = VoiceLaunchCenter()
    @Published private(set) var request: UUID?
    private(set) var ownerWindowID: String?

    func claim(_ id: UUID, windowID: String, isKeyScene: Bool) -> Bool {
        guard request == id, isKeyScene, ownerWindowID == nil else { return false }
        ownerWindowID = windowID
        return true
    }

    func requestLaunch() {
        guard request == nil else { return }
        request = UUID()
    }

    func finish() { request = nil; ownerWindowID = nil }
}

struct StartLiveConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Live Conversation"
    static let description = IntentDescription("Open Term LLM and start a live voice conversation with your selected agent.")
    static let openAppWhenRun: Bool = true

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }
    #endif

    @MainActor
    func perform() async throws -> some IntentResult {
        VoiceLaunchCenter.shared.requestLaunch()
        return .result()
    }
}

struct VoiceAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartLiveConversationIntent(),
                    phrases: ["Start a live conversation in \(.applicationName)"],
                    shortTitle: "Start Live Conversation", systemImageName: "waveform")
    }
}
