import Foundation

/// Device tools and which servers may use them. Tools reach a server only
/// through its web page (WebMCP), so the opt-in is per server base URL — for
/// example a personal hub, but not a development box.
@MainActor
final class DeviceToolsSettings: ObservableObject {
    static let shared = DeviceToolsSettings(
        registry: DeviceToolRegistry(tools: BuiltInDeviceTools.standard + MusicLibrary.shared.tools + NavigationService.shared.tools
                                    + Listen.shared.tools))
    static let serversKey = "deviceTools.webMCPServers"

    let registry: DeviceToolRegistry
    @Published private(set) var enabledServers: Set<String>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard,
         registry: DeviceToolRegistry = BuiltInDeviceTools.standardRegistry()) {
        self.defaults = defaults
        self.registry = registry
        self.enabledServers = Set(defaults.stringArray(forKey: Self.serversKey) ?? [])
    }

    func isEnabled(for server: URL) -> Bool {
        enabledServers.contains(server.absoluteString)
    }

    func setEnabled(_ enabled: Bool, for server: URL) {
        if enabled { enabledServers.insert(server.absoluteString) } else { enabledServers.remove(server.absoluteString) }
        defaults.set(enabledServers.sorted(), forKey: Self.serversKey)
    }
}
