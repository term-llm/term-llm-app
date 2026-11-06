import Foundation

/// Explicitly scoped trust for the companion's own local service.
///
/// Ordinary remote connections keep normal HTTPS validation. Plain HTTP is
/// accepted only for a loopback origin that the core reports as an installed,
/// managed service, and only for the exact host/port/base path it reports.
public struct ManagedLoopbackEndpoint: Equatable, Sendable {
    public enum Rejection: Error, LocalizedError, Equatable {
        case notInstalled
        case unmanaged
        case missingURL
        case invalidURL(String)
        case notLoopback(String)
        case notHTTP(String)
        case invalidPort
        case missingBasePath

        public var errorDescription: String? {
            switch self {
            case .notInstalled: return "There is no installed local service to connect to."
            case .unmanaged: return "The local service is not managed by this app; it is left untouched."
            case .missingURL: return "The service did not report a URL."
            case .invalidURL(let value): return "The service reported an unusable URL: \(value)"
            case .notLoopback(let host): return "Refusing a non-loopback service host: \(host)"
            case .notHTTP(let scheme): return "The managed service must use its loopback HTTP listener; got \(scheme)."
            case .invalidPort: return "The service did not report a valid loopback port."
            case .missingBasePath: return "The service did not report a base path."
            }
        }
    }

    public let baseURL: URL
    public let host: String
    public let port: Int
    /// Always starts and ends with `/` (for example `/` or `/term/`).
    public let basePath: String

    /// Validates a `service status --json` entry. The caller must pass the entry
    /// for the kind it intends to open (typically `web`).
    public static func make(from status: ServiceStatus) -> Result<ManagedLoopbackEndpoint, Rejection> {
        guard status.installed else { return .failure(.notInstalled) }
        guard status.managed else { return .failure(.unmanaged) }
        guard let rawURL = status.url, !rawURL.isEmpty else { return .failure(.missingURL) }
        guard let components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty else {
            return .failure(.invalidURL(rawURL))
        }
        guard scheme == "http" else { return .failure(.notHTTP(scheme)) }
        // IPv4 loopback and the localhost name only. An IPv6 literal would need
        // bracketed URL construction and an ATS exception, so it fails closed.
        guard ["127.0.0.1", "localhost"].contains(host.lowercased()) else {
            return .failure(.notLoopback(host))
        }
        guard components.user == nil, components.password == nil else {
            return .failure(.invalidURL(rawURL))
        }
        let port = status.port ?? components.port ?? 0
        guard port > 0, port <= 65535 else { return .failure(.invalidPort) }
        guard components.port == nil || components.port == port else {
            return .failure(.invalidURL(rawURL))
        }
        let reported = status.basePath ?? components.path
        guard !reported.isEmpty else { return .failure(.missingBasePath) }
        let basePath = Self.normalizedBasePath(reported)
        guard let baseURL = URL(string: "http://\(host):\(port)\(basePath)") else {
            return .failure(.invalidURL(rawURL))
        }
        return .success(ManagedLoopbackEndpoint(baseURL: baseURL,
                                                host: host,
                                                port: port,
                                                basePath: basePath))
    }

    static func normalizedBasePath(_ value: String) -> String {
        var path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.hasPrefix("/") { path = "/" + path }
        if !path.hasSuffix("/") { path += "/" }
        // Collapse a bare root and reject traversal/control characters later in
        // `allows(_:)`; the core emits a normalized path.
        return path
    }

    /// Navigation policy for the embedded chat: exactly this origin, under the
    /// configured base path, with no embedded credentials.
    public func allows(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "http",
              let host = components.host?.lowercased(),
              host == self.host.lowercased(),
              (components.port ?? 80) == port,
              components.user == nil, components.password == nil else {
            return false
        }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if basePath == "/" { return true }
        let prefix = String(basePath.dropLast())
        return path == prefix || path.hasPrefix(basePath) || path.hasPrefix(prefix + "?")
    }

    /// Local chat entry point. The frontend is the same web UI the server
    /// serves; this app does not reimplement chat.
    public var chatURL: URL { baseURL }

    public func healthURL() -> URL {
        baseURL.appendingPathComponent("healthz")
    }

    /// Protected JSON endpoint used to prove the bearer credential. It is
    /// registered behind the core's auth middleware (unlike unknown `/api/...`
    /// paths, which the web UI answers with its 200 text/html SPA shell).
    public var capabilitiesURL: URL {
        baseURL.appendingPathComponent("v1/capabilities")
    }
}

/// Human-facing readiness derived from service status. Kept separate from the
/// transport so onboarding can explain exactly what remains.
public enum ChatReadiness: Equatable, Sendable {
    case ready
    case needsServiceInstall
    case needsStart
    case needsAuthentication
    case passkeyEnrollmentRequired
    case unmanagedService
    case unhealthy(String)
    case unsupported(String)
}
