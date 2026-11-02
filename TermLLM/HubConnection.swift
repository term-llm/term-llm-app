import Foundation
import WebKit

/// Simulator-only protocol fixture. Never borrows production cookies or settings.
enum HubFixture {
    static var server: URL? {
        #if DEBUG && targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["TERMLLM_NATIVE_HUB_FIXTURE_URL"] == "http://localhost:8766/" else { return nil }
        return URL(string: "http://localhost:8766/")
        #else
        return nil
        #endif
    }

    static var isEnabled: Bool { server != nil }
    // UserDefaults is documented thread-safe.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        if PhoneHubFixture.isEnabled { return PhoneHubFixture.defaults }
        guard isEnabled else { return .standard }
        let name = "com.termllm.app.native-hub-fixture"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }()
    @MainActor static let websiteDataStore = WKWebsiteDataStore.nonPersistent()
}

/// Untrusted pairing links contain a server address, never a bearer token. Import
/// only fills a confirmation form; it never signs in or changes the current server.
enum HubConnectionImport {
    static func server(from link: URL) -> URL? {
        guard link.scheme?.lowercased() == "termllm", link.host == "connect",
              link.path.isEmpty || link.path == "/", link.fragment == nil,
              link.user == nil, link.password == nil, link.port == nil,
              let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems,
              items.count == 1, items[0].name == "server", let value = items[0].value,
              let server = ServerAddress.parse(value), server.scheme == "https",
              let host = server.host?.lowercased(), host != "localhost",
              !host.hasSuffix(".localhost"), host != "127.0.0.1", host != "::1" else { return nil }
        return server
    }
}

struct HubBrowserDestination: Equatable {
    let id = UUID()
    let url: URL
    var sourceID: UUID? = nil
}

/// Context for the one retained browser workspace. This is presentation state,
/// never a new navigation request or a persisted claim of authorization.
struct ChatTabContext: Equatable {
    let sourceID: UUID
    let browserIdentity: UUID
    let agentID: String?
    let agentName: String
    let url: URL

    static func resolve(connection: HubConnection, browserIdentity: UUID, url: URL,
                        agents: [HubNode]) -> ChatTabContext? {
        guard HubNavigation.isWithinMount(url, server: connection.url) else { return nil }
        let agentID: String?
        if connection.kind == .directNode {
            agentID = agents.first?.id
        } else {
            let mountCount = connection.url.path.split(separator: "/").count
            let relative = Array(url.path.split(separator: "/").dropFirst(mountCount))
            agentID = relative.count >= 2 && relative[0] == "node" ? String(relative[1]) : nil
        }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = (parts?.percentEncodedPath ?? url.path) + (parts?.percentEncodedQuery.map { "?" + $0 } ?? "")
        parts?.query = nil
        parts?.fragment = nil
        let isSourceRoot = parts?.url == connection.url && url.query == nil && url.fragment == nil
        guard isSourceRoot || HubNavigation.chatDestination(path, server: connection.url, nodeID: agentID,
                                                            direct: connection.kind == .directNode) == url else { return nil }
        let agentName = agents.first { $0.id == agentID }?.name ?? connection.name
        return ChatTabContext(sourceID: connection.id, browserIdentity: browserIdentity,
                              agentID: agentID, agentName: agentName, url: url)
    }

    func belongs(to connection: HubConnection, browserIdentity: UUID) -> Bool {
        sourceID == connection.id && self.browserIdentity == browserIdentity &&
            HubNavigation.isWithinMount(url, server: connection.url)
    }
}

/// Public, bounded role discovery never treats a timeout/auth failure as a Hub.
/// A failed probe does not replace or interrupt the existing chat workspace.
enum HubServerRole: Equatable {
    case unknown, direct, hub

    static func classify(status: Int, data: Data) -> HubServerRole {
        guard status == 200, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unknown }
        guard object["status"] as? String == "ok", object["error"] == nil else { return .unknown }
        if object["role"] as? String == "hub" { return .hub }
        guard object["role"] == nil || object["role"] as? String == "node" else { return .unknown }
        return .direct
    }

    // A cold VPN/DNS/DERP path can take longer than the old three-second
    // budget. Keep discovery bounded without confusing a slow tailnet with an
    // unsupported server. Navigation and cancellation remain independent.
    static let discoveryTimeout: TimeInterval = 15

    enum DiscoveryFailure: LocalizedError, Equatable {
        case network(code: Int, tailnet: Bool)
        case http(Int)
        case unrecognized

        var errorDescription: String? {
            switch self {
            case .network(let code, let tailnet):
                let hint = tailnet
                    ? " Check that Tailscale is connected on both devices, the server is online, and your tailnet access rules allow this connection."
                    : " Check the server address and your network connection."
                switch URLError.Code(rawValue: code) {
                case .cannotFindHost, .dnsLookupFailed:
                    return "Could not resolve the server name." + (tailnet
                        ? " Connect Tailscale on this device and check MagicDNS and the full HTTPS .ts.net name."
                        : hint)
                case .timedOut:
                    return "The server did not respond within 15 seconds." + hint
                case .cannotConnectToHost, .networkConnectionLost:
                    return "Could not reach the server." + hint
                case .notConnectedToInternet:
                    return "The network connection is unavailable." + hint
                case .secureConnectionFailed, .serverCertificateHasBadDate,
                     .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                     .serverCertificateNotYetValid, .clientCertificateRejected,
                     .clientCertificateRequired:
                    return "Could not establish a trusted HTTPS connection. Use the hostname covered by the server’s valid certificate, not its IP address. Check the certificate and device date; certificate verification has not been bypassed."
                default:
                    return "Could not connect to the server." + hint
                }
            case .http(let status):
                if status == 401 || status == 403 {
                    return "The server’s health check requires access (HTTP \(status)). Allow the public /healthz check at the configured mount so the app can identify the server before sign-in."
                }
                if (300..<400).contains(status) {
                    return "The server’s health check redirected. Enter the final HTTPS server address, including its path prefix. Discovery does not follow redirects."
                }
                return "The server’s health check returned HTTP \(status). Check the server address, path prefix, and reverse-proxy configuration."
            case .unrecognized:
                return "Could not identify this server. Check that the address points to a term-llm Hub or Direct Node and includes its path prefix."
            }
        }
    }

    static func discover(server: URL) async -> HubServerRole {
        (try? await detect(server: server)) ?? .unknown
    }

    /// Throw actionable, credential-free diagnostics for the connection editor.
    /// Migration still uses `discover` and leaves unsuccessful probes unresolved.
    static func detect(server: URL) async throws -> HubServerRole {
        try await detect(server: server, configuration: discoveryConfiguration())
    }

    static func discoveryConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = discoveryTimeout
        configuration.timeoutIntervalForResource = discoveryTimeout
        return configuration
    }

    static func detect(server: URL, configuration: URLSessionConfiguration) async throws -> HubServerRole {
        var components = URLComponents(url: server, resolvingAgainstBaseURL: false)
        let prefix = server.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.path = (prefix.isEmpty ? "" : "/" + prefix) + "/healthz"
        guard let url = components?.url else { throw DiscoveryFailure.unrecognized }
        var request = URLRequest(url: url, timeoutInterval: discoveryTimeout)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: configuration, delegate: HubRoleRedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.url == url else { throw DiscoveryFailure.unrecognized }
            guard http.statusCode == 200 else { throw DiscoveryFailure.http(http.statusCode) }
            return classify(status: http.statusCode, data: data)
        } catch {
            try Task.checkCancellation()
            if let failure = error as? DiscoveryFailure { throw failure }
            let error = error as NSError
            if error.domain == NSURLErrorDomain {
                let host = server.host?.lowercased() ?? ""
                throw DiscoveryFailure.network(code: error.code, tailnet: host.hasSuffix(".ts.net"))
            }
            throw DiscoveryFailure.unrecognized
        }
    }
}

private final class HubRoleRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
