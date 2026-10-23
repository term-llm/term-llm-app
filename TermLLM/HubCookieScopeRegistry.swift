import Foundation
import WebKit

/// Existing Listen/Voice consumers keep their injectable ListenCookieJar, but
/// production resolves the same UUID-owned jar as the selected browser. No
/// copy to the ambient WK store (which would defeat mount isolation).
@MainActor
final class HubCookieScopeRegistry {
    static let shared = HubCookieScopeRegistry()
    private final class Entry {
        weak var security: HubConnectionSecurity?
        let kind: HubConnection.Kind
        init(_ security: HubConnectionSecurity, kind: HubConnection.Kind) { self.security = security; self.kind = kind }
    }
    private var entries: [UUID: Entry] = [:]
    var selectedID: UUID?
    func register(_ security: HubConnectionSecurity, kind: HubConnection.Kind) { entries[security.id] = Entry(security, kind: kind) }
    func kind(for server: URL) -> HubConnection.Kind? {
        entries.values.first { $0.security?.active == true && $0.security?.server == HubConnectionStore.canonicalURL(server.absoluteString) }?.kind
    }
    func unregister(_ security: HubConnectionSecurity) {
        if entries[security.id]?.security === security { entries[security.id] = nil }
    }
    func dataStore(for url: URL) -> WKWebsiteDataStore {
        let matches = entries.values.compactMap(\.security).filter { $0.active && Self.contains(url, server: $0.server) }
        if let selected = matches.first(where: { $0.id == selectedID }) { return selected.dataStore }
        if let source = matches.max(by: { $0.server.path.count < $1.server.path.count }) { return source.dataStore }
        // A saved source may be used by a background Listen operation before a
        // window constructs its aggregate. Resolve its persistent identifier.
        let defaults = PhoneHubFixture.defaults
        if let data = defaults.data(forKey: HubConnectionStore.storageKey),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let records = object["connections"] as? [[String: Any]] {
            let candidates = records.compactMap { record -> (UUID, URL)? in
                guard let rawID = record["id"] as? String, let id = UUID(uuidString: rawID),
                      let rawURL = record["url"] as? String, let server = HubConnectionStore.canonicalURL(rawURL),
                      Self.contains(url, server: server) else { return nil }
                return (id, server)
            }
            if let source = candidates.max(by: { $0.1.path.count < $1.1.path.count }) {
                return PhoneHubFixture.isEnabled ? .nonPersistent() : WKWebsiteDataStore(forIdentifier: source.0)
            }
            return .nonPersistent()
        }
        return HubFixture.isEnabled ? HubFixture.websiteDataStore : .default()
    }
    private static func contains(_ url: URL, server: URL) -> Bool {
        guard url.scheme == server.scheme, url.host?.lowercased() == server.host?.lowercased(),
              (url.port ?? (url.scheme == "https" ? 443 : 80)) == (server.port ?? (server.scheme == "https" ? 443 : 80)) else { return false }
        let root = server.path.hasSuffix("/") ? server.path : server.path + "/"
        return url.path == String(root.dropLast()) || url.path.hasPrefix(root)
    }
}
