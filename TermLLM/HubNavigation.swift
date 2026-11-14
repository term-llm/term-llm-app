import Foundation

/// Navigation supplied by the Hub is untrusted. Paths already include its mount.
enum HubNavigation {
    static func destination(_ path: String, server: URL) -> URL? {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let parts = URLComponents(string: path), parts.scheme == nil, parts.host == nil,
              !parts.percentEncodedPath.lowercased().contains("%2f"),
              !parts.percentEncodedPath.lowercased().contains("%25"),
              let decoded = parts.percentEncodedPath.removingPercentEncoding,
              !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !decoded.contains("\\"), !decoded.hasPrefix("//"),
              !decoded.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        let mount = server.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let root = mount.isEmpty ? "/" : "/" + mount + "/"
        guard decoded.hasPrefix(root) || decoded == String(root.dropLast()) else { return nil }
        var origin = URLComponents(url: server, resolvingAgainstBaseURL: false)
        origin?.percentEncodedPath = parts.percentEncodedPath
        origin?.percentEncodedQuery = parts.percentEncodedQuery
        origin?.percentEncodedFragment = parts.percentEncodedFragment
        return origin?.url
    }

    static func isWithinMount(_ url: URL, server: URL) -> Bool {
        guard url.scheme?.lowercased() == server.scheme?.lowercased(),
              url.host?.lowercased() == server.host?.lowercased(),
              (url.port ?? (url.scheme == "https" ? 443 : 80)) == (server.port ?? (server.scheme == "https" ? 443 : 80)),
              url.user == nil, url.password == nil,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return destination(parts.percentEncodedPath, server: server) != nil
    }

    /// Only real chat routes, not arbitrary same-origin API/auth paths. Hub
    /// node IDs are untrusted too; never derive a destination from node.url.
    static func chatDestination(_ path: String, server: URL, nodeID: String?, direct: Bool) -> URL? {
        guard let url = destination(path, server: server),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.fragment == nil else { return nil }
        let mount = server.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var root = mount.isEmpty ? "/" : "/" + mount + "/"
        if !direct {
            guard let nodeID, !nodeID.isEmpty, nodeID != ".", nodeID != "..",
                  nodeID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }) else { return nil }
            root += "node/" + nodeID + "/"
        }
        if parts.path == root {
            guard parts.query == nil || parts.query == "new=1" else { return nil }
            return url
        }
        guard parts.query == nil, parts.path.hasPrefix(root + "chat/") else { return nil }
        let selector = String(parts.path.dropFirst((root + "chat/").count))
        guard !selector.isEmpty, selector != ".", selector != "..",
              selector.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return url
    }

    /// File previews are documents, not chat routes. Opening one in the retained
    /// chat WebView replaces the frontend (and its conversation controls).
    static func isFileDocument(_ url: URL, server: URL) -> Bool {
        guard isWithinMount(url, server: server) else { return false }
        let mount = server.path.split(separator: "/")
        let path = Array(url.path.split(separator: "/").dropFirst(mount.count))
        if path.first == "files" { return true }
        return path.count >= 3 && path[0] == "node" && path[2] == "files"
    }

    static func nodeSessions(_ node: HubNode) -> [HubNodeSession] {
        var seen = Set<String>()
        return ((node.sessions?.active ?? []) + (node.sessions?.recent ?? [])).filter { seen.insert($0.id).inserted }
    }
}

extension HubInputRequiredItem {
    var hubIdentity: [String] { [nodeID, sessionID] }
}

extension HubAttentionInboxItem {
    var hubIdentity: [String] { [nodeID, storeInstanceID ?? "", sessionID, String(attentionSeq)] }
}
