import Combine
import Foundation

struct HubConnection: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case hub, directNode
        var title: String { self == .hub ? "Hub" : "Direct Node" }
    }
    let id: UUID
    var name: String
    var kind: Kind
    var url: URL
    var needsKindReview: Bool?
    /// Present only for a Linked devices source. This pinned Ed25519 host key,
    /// not the loopback browser URL, is the durable source/trust identity.
    var linkedDevicesHostKey: String? = nil
    var isLinkedDevices: Bool { linkedDevicesHostKey != nil }
    var mountPath: String {
        let prefix = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return prefix.isEmpty ? "/" : "/" + prefix + "/"
    }
}

/// Metadata only. Credentials belong to the connection's protected storage,
/// never this defaults document or the legacy URL mirror.
@MainActor
final class HubConnectionStore: ObservableObject {
    nonisolated static let storageKey = "phoneHub.connections.v1"
    struct Document: Codable {
        var connections: [HubConnection]
        var selectedID: UUID?
    }
    @Published private(set) var connections: [HubConnection] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var persistenceError: String?
    private let defaults: UserDefaults
    var selected: HubConnection? { connections.first { $0.id == selectedID } }

    init(defaults: UserDefaults = .standard, legacyKind: HubConnection.Kind? = nil) {
        self.defaults = defaults
        if let raw = defaults.object(forKey: Self.storageKey) {
            guard let doc = try? Self.validatedDocument(raw) else {
                persistenceError = "Saved connections could not be read or validated. The original catalog has been preserved. Reset it explicitly to start again."
                return
            }
            connections = doc.connections
            selectedID = doc.selectedID ?? connections.first?.id
        } else if let legacy = defaults.string(forKey: "serverURL"), let url = Self.canonicalURL(legacy) {
            let source = HubConnection(id: UUID(), name: url.host ?? "Connection", kind: legacyKind ?? .directNode, url: url, needsKindReview: legacyKind == nil ? true : nil)
            connections = [source]
            selectedID = source.id
        }
        persist()
    }

    /// Single, side-effect-free validation path for UI and credential readers.
    /// A missing catalog is not permission to borrow the ambient WebKit jar.
    static func validatedDocument(_ raw: Any?) throws -> Document {
        try validatedDocument(raw, canonicalOrdinaryURL: { canonicalURL($0) })
    }

    static func validatedDocument(_ raw: Any?,
                                  canonicalOrdinaryURL: (String) -> URL?) throws -> Document {
        guard let data = raw as? Data,
              var doc = try? JSONDecoder().decode(Document.self, from: data),
              Set(doc.connections.map(\.id)).count == doc.connections.count,
              doc.selectedID == nil || doc.connections.contains(where: { $0.id == doc.selectedID }) else { throw ValidationError.corrupt }
        var identities = Set<String>()
        var endpoints = Set<String>()
        for index in doc.connections.indices {
            let source = doc.connections[index]
            let url = source.linkedDevicesHostKey == nil
                ? canonicalOrdinaryURL(source.url.absoluteString)
                : canonicalLinkedDevicesBridgeURL(source.url.absoluteString)
            guard !source.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let url, endpoints.insert(url.absoluteString).inserted else {
                throw ValidationError.corrupt
            }
            if let encodedKey = source.linkedDevicesHostKey {
                guard source.kind == .directNode, source.needsKindReview != true,
                      let key = LinkedDevicesBase64URL.decode(encodedKey, maximumBytes: 32), key.count == 32,
                      Self.isLinkedDevicesBridgeURL(url), identities.insert("peer:\(encodedKey)").inserted else {
                    throw ValidationError.corrupt
                }
            } else {
                guard identities.insert("http:\(url.absoluteString)").inserted else { throw ValidationError.corrupt }
            }
            doc.connections[index].url = url
        }
        return doc
    }

    /// The legacy app never persisted role. A bounded public probe may resolve
    /// it, but timeout/401 leaves it unresolved rather than guessing.
    func resolveLegacyKinds(discover: (URL) async -> HubServerRole = HubServerRole.discover) async {
        let pending = connections.filter { $0.needsKindReview == true }
        for source in pending {
            let role = await discover(source.url)
            guard !Task.isCancelled, let index = connections.firstIndex(where: { $0 == source }) else { continue }
            guard role == .hub || role == .direct else { continue }
            connections[index].kind = role == .hub ? .hub : .directNode
            connections[index].needsKindReview = nil
            persist()
        }
    }

    func resetUnreadableCatalog() {
        guard persistenceError != nil else { return }
        connections = []
        selectedID = nil
        persistenceError = nil
        persist()
    }

    static func canonicalURL(_ input: String) -> URL? {
        guard let url = ServerAddress.parse(input),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              !parts.percentEncodedPath.contains("%"), !url.path.contains("\\"),
              !url.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !url.path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }),
              !url.path.contains("//") else { return nil }
        var normalized = parts
        normalized.scheme = parts.scheme?.lowercased()
        normalized.host = parts.host?.lowercased()
        if normalized.port == (normalized.scheme == "https" ? 443 : 80) { normalized.port = nil }
        normalized.path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        normalized.path = normalized.path.isEmpty ? "/" : "/" + normalized.path + "/"
        return normalized.url
    }

    /// Dedicated validator for the app-owned loopback bridge. It deliberately
    /// does not call `ServerAddress.parse`: physical devices reject arbitrary
    /// HTTP servers, while this narrowly constrained URL is local metadata.
    static func canonicalLinkedDevicesBridgeURL(_ input: String) -> URL? {
        guard var parts = URLComponents(string: input),
              parts.scheme?.lowercased() == "http", parts.host?.lowercased() == "localhost",
              let port = parts.port, (1024...65535).contains(port),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              !parts.percentEncodedPath.contains("%"), !parts.path.contains("\\"),
              !parts.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !parts.path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }),
              !parts.path.contains("//") else { return nil }
        parts.scheme = "http"
        parts.host = "localhost"
        let path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.path = path.isEmpty ? "/" : "/" + path + "/"
        return parts.url
    }

    static func isLinkedDevicesBridgeURL(_ url: URL) -> Bool {
        canonicalLinkedDevicesBridgeURL(url.absoluteString) == url
    }

    /// Adds or updates a paired source by its pinned host identity. The local
    /// bridge URL is presentation/transport metadata and never its identity.
    @discardableResult
    func saveLinkedDevices(id: UUID? = nil, name: String, hostKey: Data, bridgePort: UInt16,
                           basePath: String = "/") throws -> HubConnection {
        let normalizedPath = basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = normalizedPath.isEmpty ? "/" : "/" + normalizedPath + "/"
        guard persistenceError == nil, hostKey.count == 32, bridgePort >= 1024,
              LinkedDevicesCrypto.validBasePath(basePath),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: "http://localhost:\(bridgePort)\(path)") else { throw ValidationError.invalid }
        let encodedKey = LinkedDevicesBase64URL.encode(hostKey)
        if let index = connections.firstIndex(where: { $0.linkedDevicesHostKey == encodedKey }) {
            connections[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            // Keep the original port/origin but follow the newly signed mount.
            guard let oldPort = connections[index].url.port,
                  let updated = URL(string: "http://localhost:\(oldPort)\(path)"),
                  let canonical = Self.canonicalLinkedDevicesBridgeURL(updated.absoluteString) else {
                throw ValidationError.corrupt
            }
            connections[index].url = canonical
            connections[index].needsKindReview = nil
            persist()
            return connections[index]
        }
        guard !connections.contains(where: { $0.url == url }) else { throw ValidationError.duplicate }
        let source = HubConnection(id: id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                   kind: .directNode, url: url, needsKindReview: nil,
                                   linkedDevicesHostKey: encodedKey)
        connections.append(source)
        if selectedID == nil { selectedID = source.id }
        persist()
        return source
    }

    /// Discover new endpoints without borrowing credentials or guessing on failure.
    /// Label-only edits of verified endpoints also work while the server is offline.
    @discardableResult
    func saveDetectingKind(id: UUID? = nil, name: String, address: String,
                           discover: (URL) async throws -> HubServerRole = HubServerRole.detect) async throws -> HubConnection {
        guard persistenceError == nil else { throw ValidationError.corrupt }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = Self.canonicalURL(address) else { throw ValidationError.invalid }
        guard !connections.contains(where: { $0.id != id && $0.url == url }) else { throw ValidationError.duplicate }
        let previous = connections.first { $0.id == id }
        if id != nil && previous == nil { throw ValidationError.missing }
        let kind: HubConnection.Kind
        if let previous, previous.url == url, previous.needsKindReview != true {
            kind = previous.kind
        } else {
            let role = try await discover(url)
            try Task.checkCancellation()
            guard role != .unknown else { throw ValidationError.discoveryFailed }
            kind = role == .hub ? .hub : .directNode
        }
        try Task.checkCancellation()
        // Do not overwrite a connection edited or removed while discovery ran.
        if let id, connections.first(where: { $0.id == id }) != previous { throw ValidationError.missing }
        return try save(id: id, name: name, kind: kind, address: url.absoluteString)
    }

    @discardableResult
    func save(id: UUID? = nil, name: String, kind: HubConnection.Kind, address: String) throws -> HubConnection {
        guard persistenceError == nil else { throw ValidationError.corrupt }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let url = Self.canonicalURL(address) else { throw ValidationError.invalid }
        guard !connections.contains(where: { $0.id != id && $0.url == url }) else { throw ValidationError.duplicate }
        var source = HubConnection(id: id ?? UUID(), name: name, kind: kind, url: url)
        if let id {
            guard let index = connections.firstIndex(where: { $0.id == id }) else { throw ValidationError.missing }
            let previous = connections[index]
            if previous.url != url || previous.kind != kind {
                // Endpoint/kind is a new trust realm, not just a label edit.
                source = HubConnection(id: UUID(), name: name, kind: kind, url: url)
                if selectedID == id { selectedID = source.id }
            }
            connections[index] = source
        } else { connections.append(source) }
        if selectedID == nil { selectedID = source.id }
        persist()
        return source
    }

    func select(_ id: UUID) {
        guard connections.contains(where: { $0.id == id }) else { return }
        selectedID = id
        persist()
    }
    func remove(_ id: UUID) {
        connections.removeAll { $0.id == id }
        if selectedID == id { selectedID = connections.first?.id }
        persist()
    }
    private func persist() {
        guard persistenceError == nil else { return }
        if let data = try? JSONEncoder().encode(Document(connections: connections, selectedID: selectedID)) {
            defaults.set(data, forKey: Self.storageKey)
        }
        defaults.set(selected?.url.absoluteString ?? "", forKey: "serverURL")
    }
    enum ValidationError: LocalizedError {
        case invalid, duplicate, missing, corrupt, discoveryFailed
        var errorDescription: String? {
            switch self {
            case .discoveryFailed: "Could not identify this server. Check the URL and connection, then try again."
            case .corrupt: "Reset the unreadable saved catalog before making changes."
            case .invalid: "Enter a name and an HTTPS server URL without query, credentials, or ambiguous path components."
            case .duplicate: "This endpoint is already saved. Edit the existing connection instead."
            case .missing: "This connection was removed."
            }
        }
    }
}
