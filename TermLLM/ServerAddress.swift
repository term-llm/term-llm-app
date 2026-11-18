import Foundation

enum ServerAddress {
    static let demo = "https://demo.term-llm.com/"

    // URLSession’s -1009 doesn’t say whether the internet is down or only
    // this route is unavailable (including a possible privacy restriction).
    static var unreachableMessage: String {
        let message = "Couldn’t reach this server."
        #if os(iOS)
        return message + " If the server is on your local network, check that term-llm is allowed under Settings → Privacy & Security → Local Network."
        #else
        if #available(macOS 15, *) {
            return message + " If the server is on your local network, check that term-llm is allowed under System Settings → Privacy & Security → Local Network."
        }
        return message + " Check the server address and your network connection."
        #endif
    }

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

    /// Browser entry point for a saved source. Ordinary input keeps the HTTPS
    /// policy; only a matching, validated, host-keyed source may use the app's
    /// HTTP loopback bridge on a physical iPhone.
    @MainActor
    static func browserURL(_ input: String, selectedConnection: HubConnection?) -> URL? {
        #if os(macOS)
        if let source = selectedConnection, source.isManagedLocalService {
            guard source.kind == .directNode, !source.isLinkedDevices,
                  source.needsKindReview != true,
                  HubConnectionStore.canonicalManagedLocalServiceURL(source.url.absoluteString) == source.url,
                  HubConnectionStore.canonicalManagedLocalServiceURL(input) == source.url else { return nil }
            return source.url
        }
        #endif
        guard let source = selectedConnection, source.isLinkedDevices else { return parse(input) }
        guard source.kind == .directNode, source.needsKindReview != true,
              let encodedKey = source.linkedDevicesHostKey,
              let hostKey = LinkedDevicesBase64URL.decode(encodedKey, maximumBytes: 32), hostKey.count == 32,
              HubConnectionStore.canonicalLinkedDevicesBridgeURL(source.url.absoluteString) == source.url,
              HubConnectionStore.canonicalLinkedDevicesBridgeURL(input) == source.url else { return nil }
        return source.url
    }

    static func allowsLocalHTTP(host: String) -> Bool {
        #if targetEnvironment(simulator)
        return host.lowercased() == "localhost"
        #elseif DEBUG && os(macOS)
        // Debug fixtures only: a Mac app otherwise keeps the HTTPS policy.
        return (PhoneHubFixture.isEnabled || HubFixture.isEnabled) && host.lowercased() == "localhost"
        #else
        return false
        #endif
    }
}
