import Foundation
import WebKit

/// Resolves an operation's immutable source UUID, never the currently selected
/// connection. All credential reads require the same whole-catalog validation
/// used by the connection editor. No production fallback to ambient credentials.
@MainActor
final class HubCookieScopeRegistry {
    static let shared = HubCookieScopeRegistry()
    private final class Entry {
        weak var security: HubConnectionSecurity?
        init(_ security: HubConnectionSecurity) { self.security = security }
    }
    private var entries: [UUID: Entry] = [:]
    private let defaults: UserDefaults
    // Retained for callers that mirror selection; deliberately NOT credential authority.
    var selectedID: UUID?
    init(defaults: UserDefaults = PhoneHubFixture.defaults) { self.defaults = defaults }
    private var catalog: [HubConnection]? {
        try? HubConnectionStore.validatedDocument(defaults.object(forKey: HubConnectionStore.storageKey)).connections
    }
    func register(_ security: HubConnectionSecurity, kind: HubConnection.Kind) { entries[security.id] = Entry(security) }
    func unregister(_ security: HubConnectionSecurity) {
        if entries[security.id]?.security === security { entries[security.id] = nil }
    }
    func connection(_ id: UUID) -> HubConnection? {
        catalog?.first { $0.id == id && $0.needsKindReview != true }
    }
    func sourceID(forServer server: URL) -> UUID? {
        guard let url = HubConnectionStore.canonicalURL(server.absoluteString) else { return nil }
        return catalog?.first { $0.url == url && $0.needsKindReview != true }?.id
    }
    func kind(for server: URL) -> HubConnection.Kind? {
        sourceID(forServer: server).flatMap(connection)?.kind
    }
    /// Only for callers without an explicit source (e.g. legacy Voice probes).
    /// Overlapping mounts are ambiguous, regardless of selection/longest path.
    func unambiguousSourceID(for url: URL) -> UUID? {
        guard let catalog else { return nil }
        let matches = catalog.filter { $0.needsKindReview != true && HubNavigation.isWithinMount(url, server: $0.url) }
        return matches.count == 1 ? matches.first?.id : nil
    }
    func dataStore(for url: URL, sourceID: UUID? = nil) -> WKWebsiteDataStore {
        resolvedDataStore(for: url, sourceID: sourceID) ?? .nonPersistent()
    }
    private func resolvedDataStore(for url: URL, sourceID: UUID?) -> WKWebsiteDataStore? {
        if HubFixture.isEnabled, sourceID == nil { return HubFixture.websiteDataStore }
        guard let sourceID, let source = connection(sourceID), HubNavigation.isWithinMount(url, server: source.url) else { return nil }
        if let security = entries[sourceID]?.security {
            guard security.active, security.cookiesReadable, security.server == source.url else { return nil }
            return security.dataStore
        }
        // Background media can resolve a persisted UUID before any window owns
        // its workspace. Fixtures never open a production persistent store.
        return PhoneHubFixture.isEnabled ? nil : WKWebsiteDataStore(forIdentifier: sourceID)
    }
    func cookies(for url: URL, sourceID: UUID?) async -> [HTTPCookie] {
        guard let store = resolvedDataStore(for: url, sourceID: sourceID) else { return [] }
        let owner = sourceID.flatMap(connection)
        let security = sourceID.flatMap { entries[$0]?.security }
        let epoch = security?.epoch
        let cookies = await store.httpCookieStore.allCookies()
        guard sourceID == nil ? HubFixture.isEnabled : sourceID.flatMap(connection) == owner,
              security == nil || (security?.active == true && security?.cookiesReadable == true && security?.epoch == epoch) else { return [] }
        return WebKitCookieJar.matching(cookies, url: url)
    }
}
