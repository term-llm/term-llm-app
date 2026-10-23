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
    var mountPath: String {
        let prefix = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return prefix.isEmpty ? "/" : "/" + prefix + "/"
    }
}

/// Metadata only. Credentials belong to the connection's protected storage,
/// never this defaults document or the legacy URL mirror.
@MainActor
final class HubConnectionStore: ObservableObject {
    static let storageKey = "phoneHub.connections.v1"
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
        guard let data = raw as? Data,
              var doc = try? JSONDecoder().decode(Document.self, from: data),
              Set(doc.connections.map(\.id)).count == doc.connections.count,
              doc.selectedID == nil || doc.connections.contains(where: { $0.id == doc.selectedID }) else { throw ValidationError.corrupt }
        var endpoints = Set<String>()
        for index in doc.connections.indices {
            let source = doc.connections[index]
            guard let url = canonicalURL(source.url.absoluteString),
                  !source.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  endpoints.insert(url.absoluteString).inserted else { throw ValidationError.corrupt }
            doc.connections[index].url = url
        }
        return doc
    }

    /// The legacy app never persisted role. A bounded public probe may resolve
    /// it, but timeout/401 leaves an explicit review choice rather than guessing.
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
        case invalid, duplicate, missing, corrupt
        var errorDescription: String? {
            switch self {
            case .corrupt: "Reset the unreadable saved catalog before making changes."
            case .invalid: "Enter a name and an HTTPS server URL without query, credentials, or ambiguous path components."
            case .duplicate: "This endpoint is already saved. Edit the existing connection instead."
            case .missing: "This connection was removed."
            }
        }
    }
}
