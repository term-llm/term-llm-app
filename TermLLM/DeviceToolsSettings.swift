import Foundation
import SwiftUI
import UIKit

/// Device tools and whether agents may use them. Tools reach an agent only
/// through its open chat page (WebMCP); one switch covers every connection.
@MainActor
final class DeviceToolsSettings: ObservableObject {
    static let shared = DeviceToolsSettings(
        registry: DeviceToolRegistry(tools: BuiltInDeviceTools.standard + MusicLibrary.shared.tools + NavigationService.shared.tools
                                    + Listen.shared.tools))
    static let enabledKey = "deviceTools.enabled"
    /// Former per-server opt-in; any entry migrates to the global switch.
    static let legacyServersKey = "deviceTools.webMCPServers"

    let registry: DeviceToolRegistry
    private var sourceRegistries: [UUID: (registry: DeviceToolRegistry, provider: ListenTools)] = [:]
    private let listen: Listen?
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard,
         registry: DeviceToolRegistry = BuiltInDeviceTools.standardRegistry(), listen: Listen? = nil) {
        self.defaults = defaults
        self.registry = registry
        self.listen = listen
        if defaults.object(forKey: Self.enabledKey) == nil,
           let legacy = defaults.stringArray(forKey: Self.legacyServersKey) {
            defaults.set(!legacy.isEmpty, forKey: Self.enabledKey)
        }
        defaults.removeObject(forKey: Self.legacyServersKey)
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    func registry(for source: HubConnection) -> DeviceToolRegistry {
        if let cached = sourceRegistries[source.id] { return cached.registry }
        // Tool closures weakly capture the provider; retain it for the cached registry lifetime.
        let provider = ListenTools(listen: listen ?? .shared, source: ListenServer(base: source.url, sourceID: source.id))
        let scoped = DeviceToolRegistry(tools: registry.tools.filter { !$0.name.hasPrefix("media_") } + provider.tools)
        sourceRegistries[source.id] = (scoped, provider)
        return scoped
    }
}

/// Plain-language explanation of what "Share device tools" exposes.
struct DeviceToolsInfoView: View {
    var platform: DeviceToolPlatform = .current
    var deviceModel: String = UIDevice.current.model

    var statusTitle: String { "\(platform == .mac ? platform.name : deviceModel) status" }
    var statusSummary: String { "Battery, \(platform.systemVersionLabel) and whether the app is open." }

    private struct ToolGroup: Identifiable {
        let id: String
        let symbol: String
        let summary: String
    }

    private var groups: [ToolGroup] {
        [
            ToolGroup(id: statusTitle, symbol: platform.symbol, summary: statusSummary),
            ToolGroup(id: "Location & directions", symbol: "location", summary: "Your current location. Preview, start and stop turn-by-turn directions."),
            ToolGroup(id: "Music", symbol: "music.note", summary: "Search Apple Music, play and control playback, and edit your playlists."),
            ToolGroup(id: "Podcasts & audio", symbol: "dot.radiowaves.left.and.right", summary: "Add, play and manage episodes and audio."),
        ]
    }

    var body: some View {
        List {
            Section {
                ForEach(groups) { group in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.id)
                            Text(group.summary).font(.subheadline).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: group.symbol)
                    }
                }
            } header: {
                Text("Agents can use")
            } footer: {
                Text("Tools only work while a chat is open in this app. Nothing runs in the background or listens on the network.")
            }
            Section {
                Text("Each conversation shows these tools in its MCP servers list, where you can turn them off for that conversation.")
            } header: {
                Text("Per conversation")
            }
        }
        .navigationTitle("Device tools")
        .navigationBarTitleDisplayMode(.inline)
    }
}
