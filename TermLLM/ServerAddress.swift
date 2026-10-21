import Foundation

enum ServerAddress {
    static let demo = "https://demo.term-llm.com/"

    static func parse(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              (scheme == "https" || (scheme == "http" && allowsLocalHTTP(host: host))),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let url = components.url else { return nil }
        // Normalize bare origins; preserve explicit prefixes and routes as entered.
        if components.path.isEmpty { components.path = "/" }
        return components.url ?? url
    }

    static func allowsLocalHTTP(host: String) -> Bool {
        #if targetEnvironment(simulator)
        return host.lowercased() == "localhost"
        #else
        return false
        #endif
    }
}
