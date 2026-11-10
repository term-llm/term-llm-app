import Foundation

/// Proves the app's local credential is accepted by the running service.
///
/// The probe deliberately uses a **protected JSON API** (`/v1/capabilities`),
/// not `/api/auth/session`: bearer-mode web serves its SPA shell for unknown
/// `/api/...` paths with `200 text/html`, which would turn any 2xx check into a
/// false positive. The response must be JSON with the expected capabilities
/// shape and must not be a redirect. Cookies and caches are disabled so ambient
/// state cannot influence the result.
public enum LocalSessionProbe {
    public enum Outcome: Equatable, Sendable {
        case authenticated
        case unauthorized(Int)
        case redirected(Int)
        case invalidResponse(String)
        case unreachable(String)
        case unexpected(Int)

        public var isAuthenticated: Bool { self == .authenticated }

        public var description: String {
            switch self {
            case .authenticated:
                return "Authentication accepted by the local service."
            case .unauthorized(let status):
                return "The local service rejected the stored credential (HTTP \(status))."
            case .redirected(let status):
                return "The credential probe was redirected (HTTP \(status)); it was not followed."
            case .invalidResponse(let reason):
                return "The local service did not return the expected protected JSON (\(reason))."
            case .unreachable(let reason):
                return "Could not reach the local service: \(reason)"
            case .unexpected(let status):
                return "The local service returned an unexpected status (HTTP \(status))."
            }
        }
    }

    /// A route registered behind the core's `auth` middleware. It returns JSON
    /// for a valid bearer credential and `401 application/json` otherwise.
    static let protectedPath = "v1/capabilities"

    public static func probe(endpoint: ManagedLoopbackEndpoint, token: String) async -> Outcome {
        await probe(endpoint: endpoint, token: token, session: makeSession())
    }

    static func probe(endpoint: ManagedLoopbackEndpoint,
                      token: String,
                      session: URLSession) async -> Outcome {
        let request = makeRequest(endpoint: endpoint, token: token)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable("the response was not HTTP")
            }
            if (300..<400).contains(http.statusCode) {
                return .redirected(http.statusCode)
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .unauthorized(http.statusCode)
            }
            guard (200..<300).contains(http.statusCode) else {
                return .unexpected(http.statusCode)
            }
            if let finalURL = http.url, finalURL != request.url {
                return .redirected(http.statusCode)
            }
            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            guard contentType.hasPrefix("application/json") else {
                return .invalidResponse("content type \(contentType.isEmpty ? "<missing>" : contentType)")
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let projects = object["projects"] as? [String: Any],
                  projects["enabled"] is Bool,
                  let shell = object["shell"] as? [String: Any],
                  shell["version"] is NSNumber else {
                return .invalidResponse("unexpected capabilities shape")
            }
            return .authenticated
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    static func makeRequest(endpoint: ManagedLoopbackEndpoint, token: String) -> URLRequest {
        var request = URLRequest(url: endpoint.capabilitiesURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 6
        return request
    }

    /// Ephemeral, cookie-free, cache-free session that refuses redirects. The
    /// configuration is injectable so tests can install a URLProtocol stub.
    static func makeSession(configuration: URLSessionConfiguration? = nil) -> URLSession {
        let isolated = IsolatedSessionConfiguration.make(copying: configuration ?? .ephemeral)
        if configuration == nil {
            isolated.timeoutIntervalForRequest = 6
            isolated.timeoutIntervalForResource = 10
        }
        return URLSession(configuration: isolated,
                          delegate: RejectRedirects(),
                          delegateQueue: nil)
    }
}
