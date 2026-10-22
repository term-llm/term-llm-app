import AppIntents
import Combine
import Foundation
import SwiftUI

struct VoiceShortcutNode: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let proxyPath: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case proxyPath = "proxy_path"
    }
}

enum VoiceShortcutError: LocalizedError {
    case invalidServer, unresolved, selectAgent, invalidNode, invalidResponse, http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidServer: return "Use a valid HTTP or HTTPS server address without credentials."
        case .unresolved: return "Discover the server connection before starting a live conversation."
        case .selectAgent: return "Choose a hub agent before starting a live conversation."
        case .invalidNode: return "The hub returned an invalid agent address."
        case .invalidResponse: return "The server did not return a valid discovery response."
        case .http(let status): return "Server discovery failed (HTTP \(status)). Sign in and try again."
        }
    }
}

/// Never follows redirects: even same-origin redirects can broaden cookie scope.
final class VoiceShortcutRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class VoiceShortcutSettings: ObservableObject {
    enum ConnectionMode: String, Codable { case unknown, hub, direct }
    typealias Transport = @MainActor (URLRequest) async throws -> (Data, HTTPURLResponse)
    static let shared = VoiceShortcutSettings()
    static let storageKey = "voiceShortcut.servers"

    private struct Configuration: Codable {
        var mode: ConnectionMode = .unknown
        var nodes: [VoiceShortcutNode] = []
        var selectedNodeID: String?
    }

    @Published private var configurations: [String: Configuration]
    @Published private var errors: [String: String] = [:]
    @Published private var discovering: Set<String> = []
    private let defaults: UserDefaults
    private let cookies: any ListenCookieJar
    private let transport: Transport

    init(defaults: UserDefaults = .standard, cookies: (any ListenCookieJar)? = nil,
         transport: Transport? = nil) {
        self.defaults = defaults
        self.cookies = cookies ?? WebKitCookieJar()
        self.transport = transport ?? { request in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            let session = URLSession(configuration: configuration, delegate: VoiceShortcutRedirectBlocker(),
                                     delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw VoiceShortcutError.invalidResponse }
            return (data, response)
        }
        configurations = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([String: Configuration].self, from: $0) } ?? [:]
    }

    func mode(for server: URL) -> ConnectionMode { configuration(for: server).mode }
    func nodes(for server: URL) -> [VoiceShortcutNode] { configuration(for: server).nodes }
    func selectedNodeID(for server: URL) -> String? { configuration(for: server).selectedNodeID }
    func error(for server: URL) -> String? { errors[key(for: server)] }
    func isDiscovering(for server: URL) -> Bool { discovering.contains(key(for: server)) }

    func selectNode(_ id: String?, for server: URL) {
        let key = key(for: server)
        guard var configuration = configurations[key], configuration.mode == .hub,
              id == nil || configuration.nodes.contains(where: { $0.id == id }) else { return }
        configuration.selectedNodeID = id
        configurations[key] = configuration
        persist()
    }

    /// Root health takes precedence for hubs, even when the configured URL points
    /// at a proxied node. Direct agents must answer health at their configured base.
    /// A failure is unresolved, never evidence that the server is a direct agent.
    func discover(server: URL) async {
        let key = key(for: server)
        guard !discovering.contains(key) else { return }
        discovering.insert(key)
        errors[key] = nil
        defer { discovering.remove(key) }
        var result = Configuration()
        let previousSelection = selectedNodeID(for: server)
        do {
            var health = try Self.components(for: server)
            health.path = "/healthz"
            health.query = nil
            health.fragment = nil
            guard let healthURL = health.url else { throw VoiceShortcutError.invalidServer }
            let directHealthURL = try Self.canonicalServerURL(server).appendingPathComponent("healthz")
            let rootHealth: [String: Any]?
            do {
                rootHealth = try await healthObject(at: healthURL)
            } catch {
                // HTTP/JSON failures can mean health is mounted under the direct
                // server's base path. A transport outage is not a route mismatch.
                if error is URLError || Task.isCancelled || directHealthURL == healthURL { throw error }
                rootHealth = nil
            }
            if rootHealth?["role"] as? String == "hub" {
                result.mode = .hub
                let base = try Self.hubBase(for: server)
                let endpoint = base.appendingPathComponent("api/nodes")
                var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "view", value: "sidebar")]
                let nodes = try Self.decodeNodes(try await fetch(components.url!))
                var ids = Set<String>()
                for node in nodes {
                    _ = try Self.nodeURL(node, server: server)
                    guard ids.insert(node.id).inserted else { throw VoiceShortcutError.invalidResponse }
                }
                result.nodes = nodes
                result.selectedNodeID = nodes.contains(where: { $0.id == previousSelection }) ? previousSelection : nil
            } else {
                let directHealth: [String: Any]?
                if directHealthURL == healthURL {
                    directHealth = rootHealth
                } else {
                    directHealth = try await healthObject(at: directHealthURL)
                }
                guard directHealth?["role"] as? String != "hub",
                      directHealth?["status"] as? String == "ok" else { throw VoiceShortcutError.invalidResponse }
                result.mode = .direct
            }
            try Task.checkCancellation()
        } catch {
            guard !Task.isCancelled else { return }
            errors[key] = error.localizedDescription
            // A transient outage must not discard a previously working shortcut.
            if let previous = configurations[key], previous.mode != .unknown { return }
        }
        configurations[key] = result
        persist()
    }

    func destination(for server: URL) throws -> URL {
        _ = try Self.components(for: server)
        let configuration = configuration(for: server)
        let destination: URL
        switch configuration.mode {
        case .unknown: throw VoiceShortcutError.unresolved
        case .direct: destination = server
        case .hub:
            guard let node = configuration.nodes.first(where: { $0.id == configuration.selectedNodeID }) else {
                throw VoiceShortcutError.selectAgent
            }
            destination = try Self.nodeURL(node, server: server)
        }
        var components = try Self.components(for: destination)
        var items = (components.queryItems ?? []).filter { $0.name != "new" }
        items.append(URLQueryItem(name: "new", value: "1"))
        components.queryItems = items
        components.fragment = nil
        guard let url = components.url else { throw VoiceShortcutError.invalidServer }
        return url
    }

    static func decodeNodes(_ data: Data) throws -> [VoiceShortcutNode] {
        struct Envelope: Decodable { let nodes: [VoiceShortcutNode] }
        let decoder = JSONDecoder()
        if let array = try? decoder.decode([VoiceShortcutNode].self, from: data) { return array }
        return try decoder.decode(Envelope.self, from: data).nodes
    }

    /// Canonical keys ignore navigation query/fragment and equivalent default ports/slashes.
    static func canonicalServerURL(_ server: URL) throws -> URL {
        var components = try components(for: server)
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "https" && components.port == 443)
            || (components.scheme == "http" && components.port == 80) { components.port = nil }
        components.query = nil
        components.fragment = nil
        while components.path.hasSuffix("/") { components.path.removeLast() }
        components.path += "/"
        guard let url = components.url else { throw VoiceShortcutError.invalidServer }
        return url
    }

    static func hubBase(for server: URL) throws -> URL {
        var components = try components(for: canonicalServerURL(server))
        if let range = components.path.range(of: "/node/") {
            components.path = String(components.path[..<range.lowerBound]) + "/"
        }
        guard let url = components.url else { throw VoiceShortcutError.invalidServer }
        return url
    }

    static func nodeURL(_ node: VoiceShortcutNode, server: URL) throws -> URL {
        let base = try hubBase(for: server)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard !node.id.isEmpty, node.id != ".", node.id != "..",
              node.id.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !node.proxyPath.contains("%"), !node.proxyPath.contains("\\"),
              !node.proxyPath.hasPrefix("//"),
              let raw = URLComponents(string: node.proxyPath),
              !raw.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              let url = URL(string: node.proxyPath, relativeTo: base)?.absoluteURL,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              NativeLogin.origin(for: url) == NativeLogin.origin(for: base) else {
            throw VoiceShortcutError.invalidNode
        }
        let expected = base.appendingPathComponent("node").appendingPathComponent(node.id).path
        // Compare the raw path, not a standardized path that could conceal traversal.
        guard components.path == expected || components.path == expected + "/" else {
            throw VoiceShortcutError.invalidNode
        }
        return url
    }

    private static func components(for url: URL) throws -> URLComponents {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { throw VoiceShortcutError.invalidServer }
        return components
    }

    private func healthObject(at url: URL) async throws -> [String: Any] {
        let data = try await fetch(url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VoiceShortcutError.invalidResponse
        }
        if let role = object["role"], !(role is String) { throw VoiceShortcutError.invalidResponse }
        return object
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let matching = await cookies.cookies(for: url)
        for (name, value) in HTTPCookie.requestHeaderFields(with: matching) { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await transport(request)
        guard response.url == url else { throw VoiceShortcutError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw VoiceShortcutError.http(response.statusCode) }
        return data
    }

    private func key(for server: URL) -> String { (try? Self.canonicalServerURL(server).absoluteString) ?? server.absoluteString }
    private func configuration(for server: URL) -> Configuration { configurations[key(for: server)] ?? Configuration() }
    private func persist() { defaults.set(try? JSONEncoder().encode(configurations), forKey: Self.storageKey) }
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
    static var title: LocalizedStringResource = "Start Live Conversation"
    static var description = IntentDescription("Open Term LLM and start a live voice conversation with your selected agent.")
    static var openAppWhenRun: Bool = true

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

@MainActor
struct VoiceShortcutSection: View {
    let server: URL
    let onTest: () -> Void
    @ObservedObject private var settings = VoiceShortcutSettings.shared

    private var resolved: Bool { (try? settings.destination(for: server)) != nil }

    var body: some View {
        Section {
            switch settings.mode(for: server) {
            case .hub:
                Picker("Agent", selection: Binding(
                    get: { settings.selectedNodeID(for: server) ?? "" },
                    set: { settings.selectNode($0.isEmpty ? nil : $0, for: server) }
                )) {
                    Text("Choose an agent").tag("")
                    ForEach(settings.nodes(for: server)) { node in Text(node.name).tag(node.id) }
                }
            case .direct:
                Label("Connected directly to this agent", systemImage: "person.wave.2")
            case .unknown:
                Text("Discover your server to configure live conversations.").foregroundStyle(.secondary)
            }
            if let error = settings.error(for: server) {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Button {
                Task { await settings.discover(server: server) }
            } label: {
                HStack {
                    Text("Refresh Agents")
                    if settings.isDiscovering(for: server) { Spacer(); ProgressView() }
                }
            }
            .disabled(settings.isDiscovering(for: server))
            Button("Test Live Conversation", action: onTest)
                .disabled(!resolved || settings.isDiscovering(for: server))
        } header: {
            Text("Voice Shortcut")
        } footer: {
            Text("In iOS Settings → Action Button, choose Shortcut, then Start Live Conversation. You can also run it from Shortcuts or Siri. Your iPhone opens Term LLM to start voice with the selected agent.")
        }
        .task(id: server) { await settings.discover(server: server) }
    }
}
