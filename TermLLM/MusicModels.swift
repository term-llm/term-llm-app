import Foundation

/// An Apple Music catalog song. Only songs are supported: queueing catalog
/// albums and playlists proved unreliable with MusicKit.
struct MusicTrack: Codable, Hashable, Identifiable, Sendable {
    /// Apple Music catalog song id.
    let id: String
    var title: String
    var artist: String?
    var album: String?
    var artworkURL: URL?

    var subtitle: String {
        [artist, album].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }
}

/// A song's place in a playlist. Entries have their own id so the same song
/// can appear twice and edits never depend on positions.
struct PlaylistEntry: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var track: MusicTrack
    var addedAt: Date
}

struct Playlist: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var entries: [PlaylistEntry]
    var createdAt: Date
    var updatedAt: Date

    var tracks: [MusicTrack] { entries.map(\.track) }
    var artworkURL: URL? { entries.lazy.compactMap(\.track.artworkURL).first }
    var songCountText: String { "\(entries.count) song\(entries.count == 1 ? "" : "s")" }
}

enum MusicError: LocalizedError, Equatable {
    case notAuthorized
    case cannotPlayCatalog
    /// None of the requested songs could be found on Apple Music.
    case noPlayableSongs
    case emptyPlaylist(String)
    case nothingToResume
    case playbackFailed(String)
    /// Apple Music accepted the songs but never reported playing.
    case didNotStart
    case playlistNotFound(String, available: [String])
    case nameRequired
    case nameTaken(String)
    case invalidOrder(playlist: String, expected: Int)
    case unknownEntries([String], playlist: String)
    case unknownSongs([String])
    case storageUnavailable(String)

    // Messages are read by people and by the agent, so each one says what to
    // do next.
    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Apple Music access isn't allowed. Open Music in the term-llm app on the iPhone to connect it."
        case .cannotPlayCatalog:
            return "This Apple ID can't play Apple Music songs. Check the iPhone is signed in with an active Apple Music subscription."
        case .noPlayableSongs:
            return "None of those songs are available on Apple Music right now."
        case .emptyPlaylist(let name):
            return "\"\(name)\" has no songs yet. Add some with playlist_add_songs first."
        case .nothingToResume:
            return "Nothing to resume: nothing has been played yet. Start something with music_play."
        case .playbackFailed(let detail):
            return "Apple Music couldn't start playback (\(detail)). Try playing a song in the Music app once, then retry."
        case .didNotStart:
            return "Apple Music took the songs but didn't start playing. Check the iPhone's Music app and audio output, then try music_control with action \"resume\"."
        case .playlistNotFound(let reference, let available):
            let listing = available.isEmpty
                ? "There are no playlists yet; create one with playlist_create."
                : "Playlists: \(Self.list(available))."
            return "No playlist named or identified by \"\(reference)\". \(listing)"
        case .nameRequired:
            return "Playlists need a name."
        case .nameTaken(let name):
            return "A playlist named \"\(name)\" already exists. Pick another name, or add songs to the existing one."
        case .invalidOrder(let playlist, let expected):
            return "entry_ids must list each of the \(expected) entries in \"\(playlist)\" exactly once. Use playlist_get for the current entry ids."
        case .unknownEntries(let ids, let playlist):
            return "\(Self.list(ids)) \(ids.count == 1 ? "isn't an entry" : "aren't entries") of \"\(playlist)\". Use playlist_get for its entry ids."
        case .unknownSongs(let ids):
            return "Unknown Apple Music song ids: \(Self.list(ids)). Use music_search to find song ids."
        case .storageUnavailable(let detail):
            return "Playlists can't be changed: \(detail)"
        }
    }

    private static func list(_ items: [String], limit: Int = 20) -> String {
        let shown = items.prefix(limit).map { "\"\($0)\"" }.joined(separator: ", ")
        return items.count > limit ? "\(shown), and \(items.count - limit) more" : shown
    }
}
