import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Device tools and whether agents may use them. Tools reach an agent only
/// through its open chat page (WebMCP); one switch covers every connection.
@MainActor
final class DeviceToolsSettings: ObservableObject {
    static let shared = DeviceToolsSettings(
        registry: DeviceToolRegistry(tools: standardTools()))

    /// Keep providers lazy: Mac tools must never initialize the navigation
    /// service (and its location manager). Preserve the phone's tool order.
    static func standardTools(
        platform: DeviceToolPlatform = .current,
        builtIns: (DeviceToolPlatform) -> [DeviceTool] = { BuiltInDeviceTools.standardTools(platform: $0) },
        music: () -> [DeviceTool] = { MusicLibrary.shared.tools },
        navigation: () -> [DeviceTool] = { NavigationService.shared.tools },
        media: () -> [DeviceTool] = { Listen.shared.tools }
    ) -> [DeviceTool] {
        builtIns(platform) + music() + (platform.offersNavigation ? navigation() : []) + media()
    }
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
         registry: DeviceToolRegistry = BuiltInDeviceTools.standardRegistry(), listen: Listen? = nil,
         platform: DeviceToolPlatform = .current) {
        self.defaults = defaults
        self.registry = registry
        self.listen = listen
        if defaults.object(forKey: Self.enabledKey) == nil,
           let legacy = defaults.stringArray(forKey: Self.legacyServersKey) {
            defaults.set(!legacy.isEmpty, forKey: Self.enabledKey)
        }
        defaults.removeObject(forKey: Self.legacyServersKey)
        // Only an unsaved preference uses the host default; don't persist the fallback.
        self.isEnabled = defaults.object(forKey: Self.enabledKey) == nil
            ? platform == .mac : defaults.bool(forKey: Self.enabledKey)
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
    var deviceModel: String = NativeDevice.model

    var statusTitle: String { "\(platform == .mac ? platform.name : deviceModel) status" }
    var statusSummary: String { "Battery, \(platform.systemVersionLabel) and whether the app is open." }

    private struct ToolGroup: Identifiable {
        let id: String
        let symbol: String
        let summary: String
    }

    var groupTitles: [String] { groups.map(\.id) }

    private var groups: [ToolGroup] {
        [ToolGroup(id: statusTitle, symbol: platform.symbol, summary: statusSummary)]
        + (platform.offersNavigation ? [
            ToolGroup(id: "Location & directions", symbol: "location", summary: "Your current location. Preview, start and stop turn-by-turn directions."),
        ] : []) + [
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
        .settingsPageTitle("Device tools")
    }
}
