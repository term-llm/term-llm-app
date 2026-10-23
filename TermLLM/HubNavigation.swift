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

    static func nodeSessions(_ node: HubNode) -> [HubNodeSession] {
        var seen = Set<String>()
        return ((node.sessions?.active ?? []) + (node.sessions?.recent ?? [])).filter { seen.insert($0.id).inserted }
    }
}

extension HubInputRequiredItem {
    var hubIdentity: [String] { [node_id, session_id] }
}

extension HubAttentionInboxItem {
    var hubIdentity: [String] { [node_id, store_instance_id ?? "", session_id, String(attention_seq)] }
}
