import Foundation

/// Lenient parsing of raw Apple Music API responses. MusicKit's own decoder
/// rejects a whole page when a single item doesn't match its model; this keeps
/// every song that has an id and a name and skips the rest.
enum CatalogParsing {
    /// Songs from a `/v1/catalog/{storefront}/search` response.
    static func searchSongs(_ data: Data) -> [MusicTrack] {
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let results = root?["results"] as? [String: Any]
        let songs = results?["songs"] as? [String: Any]
        return tracks(songs?["data"])
    }

    /// Songs from a `/v1/catalog/{storefront}/songs?ids=…` response.
    static func resourceSongs(_ data: Data) -> [MusicTrack] {
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return tracks(root?["data"])
    }

    /// Short, model/user-readable description of a decoding failure.
    static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        }
        switch decoding {
        case .keyNotFound(let key, let context): return "missing \(key.stringValue) at \(path(context))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(context.debugDescription) at \(path(context))"
        @unknown default: return decoding.localizedDescription
        }
    }

    private static func tracks(_ value: Any?) -> [MusicTrack] {
        (value as? [[String: Any]] ?? []).compactMap { resource in
            guard let id = resource["id"] as? String,
                  let attributes = resource["attributes"] as? [String: Any],
                  let name = attributes["name"] as? String else { return nil }
            return MusicTrack(id: id, title: name,
                              artist: attributes["artistName"] as? String,
                              album: attributes["albumName"] as? String,
                              artworkURL: artworkURL(attributes["artwork"]))
        }
    }

    /// Artwork URLs are templates like `…/{w}x{h}bb.jpg`.
    private static func artworkURL(_ value: Any?) -> URL? {
        guard let template = (value as? [String: Any])?["url"] as? String else { return nil }
        return URL(string: template.replacingOccurrences(of: "{w}", with: "300").replacingOccurrences(of: "{h}", with: "300"))
    }
}
