import Foundation

/// The agent's music tools: small, single-purpose, and sharing the playlist
/// store and player with the Music screen, so the agent's edits show up there
/// immediately. Playlists can be referred to by id or by name.
@MainActor
final class MusicTools {
    private let store: PlaylistStore
    private let catalog: MusicCatalog
    private let player: MusicPlayer

    init(store: PlaylistStore, catalog: MusicCatalog, player: MusicPlayer) {
        self.store = store
        self.catalog = catalog
        self.player = player
    }

    var tools: [DeviceTool] {
        [
            tool("music_search", "Search Apple Music for songs. Returns song ids for the playlist and play tools.",
                 schema(["query": .string("Song, artist, or album to look for."),
                         "limit": .integer("Maximum songs, 1–25. Default 8.")], required: ["query"]),
                 readOnly: true) { try await $0.search($1) },
            tool("playlist_list", "List the playlists saved on the user's iPhone.",
                 schema([:]), readOnly: true) { tools, _ in tools.list() },
            tool("playlist_get", "Show a playlist's songs, with the entry ids used to remove or reorder them.",
                 schema(["playlist": Self.playlistParameter], required: ["playlist"]),
                 readOnly: true) { try $0.get($1) },
            tool("playlist_create", "Create a playlist on the user's iPhone, optionally with songs from music_search.",
                 schema(["name": .string("Playlist name; must be unique."), "song_ids": Self.songIDs],
                        required: ["name"])) { try await $0.create($1) },
            tool("playlist_add_songs", "Add songs (ids from music_search) to a playlist.",
                 schema(["playlist": Self.playlistParameter, "song_ids": Self.songIDs,
                         "position": .integer("Zero-based insert position. Default: the end.")],
                        required: ["playlist", "song_ids"])) { try await $0.add($1) },
            tool("playlist_remove_songs", "Remove entries (ids from playlist_get) from a playlist.",
                 schema(["playlist": Self.playlistParameter, "entry_ids": Self.entryIDs],
                        required: ["playlist", "entry_ids"])) { try $0.remove($1) },
            tool("playlist_reorder", "Set a playlist's order. entry_ids must list every entry exactly once.",
                 schema(["playlist": Self.playlistParameter, "entry_ids": Self.entryIDs],
                        required: ["playlist", "entry_ids"])) { try $0.reorder($1) },
            tool("playlist_rename", "Rename a playlist.",
                 schema(["playlist": Self.playlistParameter, "name": .string("New unique name.")],
                        required: ["playlist", "name"])) { try $0.rename($1) },
            tool("playlist_delete", "Delete a playlist from the user's iPhone. This cannot be undone.",
                 schema(["playlist": Self.playlistParameter], required: ["playlist"]),
                 consequential: true) { try $0.delete($1) },
            tool("music_play", "Play a playlist, or specific songs, on the user's iPhone through Apple Music. Give playlist or song_ids.",
                 schema(["playlist": Self.playlistParameter, "song_ids": Self.songIDs,
                         "start_entry_id": .string("Playlist entry to start from."),
                         "shuffle": .boolean("Turn shuffle on or off.")])) { try await $0.play($1) },
            tool("music_now_playing", "What the iPhone is playing, and whether it is paused.",
                 schema([:]), readOnly: true) { tools, _ in tools.nowPlaying() },
            tool("music_control", "Control playback on the iPhone.",
                 schema(["action": .enumeration(["pause", "resume", "next", "previous", "shuffle_on", "shuffle_off"])],
                        required: ["action"])) { try await $0.control($1) },
        ]
    }

    // MARK: - Tools

    private func search(_ args: Arguments) async throws -> JSONValue {
        let query = try args.string("query", "the song, artist, or album to look for")
        let songs = try await catalog.search(query, limit: try args.int("limit") ?? 8)
        return ["songs": .array(songs.map(Self.song))]
    }

    private func list() -> JSONValue {
        ["playlists": .array(store.playlists.map(Self.summary))]
    }

    private func get(_ args: Arguments) throws -> JSONValue {
        Self.detail(try playlist(args))
    }

    private func create(_ args: Arguments) async throws -> JSONValue {
        let name = try args.string("name", "the new playlist's name")
        let tracks = try await lookUp(try args.strings("song_ids") ?? [])
        return Self.detail(try store.create(name: name, tracks: tracks))
    }

    private func add(_ args: Arguments) async throws -> JSONValue {
        let playlist = try playlist(args)
        let tracks = try await lookUp(try args.requiredStrings("song_ids", Self.songIDsHint))
        try store.add(tracks, to: playlist.id, at: try args.int("position"))
        return Self.detail(try refreshed(playlist))
    }

    private func remove(_ args: Arguments) throws -> JSONValue {
        let playlist = try playlist(args)
        try store.remove(entries: Set(try args.uuids("entry_ids", Self.entryIDsHint)), from: playlist.id)
        return Self.detail(try refreshed(playlist))
    }

    private func reorder(_ args: Arguments) throws -> JSONValue {
        let playlist = try playlist(args)
        try store.reorder(playlist.id, entryIDs: try args.uuids("entry_ids", Self.entryIDsHint))
        return Self.detail(try refreshed(playlist))
    }

    private func rename(_ args: Arguments) throws -> JSONValue {
        let playlist = try playlist(args)
        try store.rename(playlist.id, to: args.string("name", "the new name"))
        return Self.summary(try refreshed(playlist))
    }

    private func delete(_ args: Arguments) throws -> JSONValue {
        let playlist = try playlist(args)
        try store.delete(playlist.id)
        return ["deleted": .string(playlist.name)]
    }

    private func play(_ args: Arguments) async throws -> JSONValue {
        let shuffle = try args.bool("shuffle")
        let reference = try args.optionalString("playlist")
        let songIDs = try args.strings("song_ids") ?? []
        let loaded: [MusicTrack]
        switch (reference, songIDs.isEmpty) {
        case (let reference?, true):
            let playlist = try store.resolve(reference)
            // A blank start_entry_id means "from the first song".
            let start = try args.optionalString("start_entry_id").map { raw in
                guard let id = UUID(uuidString: raw), playlist.entries.contains(where: { $0.id == id }) else {
                    throw MusicError.unknownEntries([raw], playlist: playlist.name)
                }
                return id
            }
            loaded = try await player.play(playlist, startingAt: start, shuffle: shuffle)
        case (nil, false):
            loaded = try await player.play(try await lookUp(songIDs), shuffle: shuffle)
        case (_?, false):
            throw DeviceToolError(message: "Give either playlist or song_ids to music_play, not both.")
        case (nil, true):
            throw DeviceToolError(message: "music_play needs a playlist (id or name, see playlist_list) or song_ids (from music_search).")
        }
        return Self.merging(nowPlaying(), ["queued": .int(loaded.count)])
    }

    private func nowPlaying() -> JSONValue {
        var result: [String: JSONValue] = [
            "status": .string(Self.status(player.status)),
            "shuffle": .bool(player.shuffle),
        ]
        if let track = player.nowPlaying { result["song"] = Self.song(track) }
        if let id = player.playlistID, let playlist = store.playlist(id: id), player.isActive(playlist) {
            result["playlist"] = .string(playlist.name)
        }
        return .object(result)
    }

    private static let actions = ["pause", "resume", "next", "previous", "shuffle_on", "shuffle_off"]

    private func control(_ args: Arguments) async throws -> JSONValue {
        let valid = "one of \(Self.actions.joined(separator: ", "))"
        switch try args.string("action", valid).lowercased() {
        case "pause": player.pause()
        case "resume", "play": try await player.resume()
        case "next", "skip": try await player.next()
        case "previous", "back": try await player.previous()
        case "shuffle_on": player.setShuffle(true)
        case "shuffle_off": player.setShuffle(false)
        case let action: throw DeviceToolError(message: "Unknown action \"\(action)\". Use \(valid).")
        }
        return nowPlaying()
    }

    // MARK: - Helpers

    private static let songIDsHint = "song ids from music_search"
    private static let entryIDsHint = "entry ids from playlist_get"

    private func playlist(_ args: Arguments) throws -> Playlist {
        try store.resolve(args.string("playlist", "a playlist id or name (see playlist_list)"))
    }

    /// Resolves song ids to metadata, rejecting ids Apple Music doesn't know.
    private func lookUp(_ ids: [String]) async throws -> [MusicTrack] {
        guard !ids.isEmpty else { return [] }
        let tracks = try await catalog.tracks(ids: ids)
        let known = Set(tracks.map(\.id))
        let unknown = ids.filter { !known.contains($0) }
        guard unknown.isEmpty else { throw MusicError.unknownSongs(unknown) }
        return tracks
    }

    private func refreshed(_ playlist: Playlist) throws -> Playlist {
        guard let current = store.playlist(id: playlist.id) else {
            throw MusicError.playlistNotFound(playlist.name, available: store.playlists.map(\.name))
        }
        return current
    }

    private func tool(_ name: String, _ description: String, _ schema: JSONValue,
                      readOnly: Bool = false, consequential: Bool = false,
                      _ run: @escaping @MainActor (MusicTools, Arguments) async throws -> JSONValue) -> DeviceTool {
        DeviceTool(name: name, description: description, inputSchema: schema,
                   readOnly: readOnly, consequential: consequential) { [weak self] arguments in
            guard let self else { throw DeviceToolError(message: "Music is unavailable.") }
            let result = try await run(self, Arguments(arguments))
            return DeviceToolResult(text: String(decoding: result.encoded(), as: UTF8.self))
        }
    }

    // MARK: - JSON

    private static func song(_ track: MusicTrack) -> JSONValue {
        var object: [String: JSONValue] = ["id": .string(track.id), "title": .string(track.title)]
        if let artist = track.artist { object["artist"] = .string(artist) }
        if let album = track.album { object["album"] = .string(album) }
        return .object(object)
    }

    private static func summary(_ playlist: Playlist) -> JSONValue {
        ["id": .string(playlist.id.uuidString), "name": .string(playlist.name),
         "songs": .int(playlist.entries.count),
         "updated": .string(ISO8601DateFormatter().string(from: playlist.updatedAt))]
    }

    private static func detail(_ playlist: Playlist) -> JSONValue {
        merging(summary(playlist), ["entries": .array(playlist.entries.map { entry in
            merging(song(entry.track), ["entry_id": .string(entry.id.uuidString)])
        })])
    }

    private static func merging(_ value: JSONValue, _ extra: [String: JSONValue]) -> JSONValue {
        .object((value.objectValue ?? [:]).merging(extra) { _, new in new })
    }

    private static func status(_ status: MusicPlayer.Status) -> String {
        switch status {
        case .idle: return "idle"
        case .loading: return "starting"
        case .playing: return "playing"
        case .paused: return "paused"
        case .failed(let message): return "failed: \(message)"
        }
    }

    // MARK: - Schemas

    private static let playlistParameter = Parameter.string("Playlist id or exact name.")
    private static let songIDs = Parameter.array("Apple Music song ids from music_search.")
    private static let entryIDs = Parameter.array("Entry ids from playlist_get.")

    private enum Parameter {
        case string(String), integer(String), boolean(String), array(String), enumeration([String])

        var json: JSONValue {
            switch self {
            case .string(let description): return ["type": "string", "description": .string(description)]
            case .integer(let description): return ["type": "integer", "description": .string(description)]
            case .boolean(let description): return ["type": "boolean", "description": .string(description)]
            case .array(let description):
                return ["type": "array", "items": ["type": "string"], "description": .string(description)]
            case .enumeration(let values): return ["type": "string", "enum": .array(values.map(JSONValue.string))]
            }
        }
    }

    private func schema(_ properties: [String: Parameter], required: [String] = []) -> JSONValue {
        [
            "type": "object",
            "properties": .object(properties.mapValues(\.json)),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": false,
        ]
    }
}

/// Typed access to a tool call's JSON arguments.
///
/// Missing, null, and blank values all mean "not given" (models often send
/// `""` for optional fields). Where intent is obvious it is accepted, e.g. a
/// number as a string or one id instead of a list; otherwise errors name the
/// argument and what it should be.
struct Arguments {
    private let values: [String: JSONValue]
    init(_ values: [String: JSONValue]) { self.values = values }

    /// A required string; `hint` describes what belongs there.
    func string(_ key: String, _ hint: String) throws -> String {
        guard let value = try optionalString(key) else {
            throw DeviceToolError(message: "\(key) is required: \(hint).")
        }
        return value
    }

    func optionalString(_ key: String) throws -> String? {
        switch values[key] {
        case nil, .null?: return nil
        case .string(let raw)?:
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        case .int(let number)?: return String(number)
        default: throw DeviceToolError(message: "\(key) must be a string.")
        }
    }

    func int(_ key: String) throws -> Int? {
        switch values[key] {
        case nil, .null?: return nil
        case .int(let value)?: return value
        case .double(let value)? where value.rounded() == value: return Int(value)
        case .string(let raw)?:
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return nil }
            if let value = Int(trimmed) { return value }
        default: break
        }
        throw DeviceToolError(message: "\(key) must be a whole number.")
    }

    func bool(_ key: String) throws -> Bool? {
        switch values[key] {
        case nil, .null?: return nil
        case .bool(let value)?: return value
        case .string(let raw)?:
            switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
            case "": return nil
            case "true", "yes", "on", "1": return true
            case "false", "no", "off", "0": return false
            default: break
            }
        default: break
        }
        throw DeviceToolError(message: "\(key) must be true or false.")
    }

    /// A list of strings. A single string (comma-separated allowed) is accepted
    /// as a list; an empty list or blank string means "not given".
    func strings(_ key: String) throws -> [String]? {
        let items: [String]
        switch values[key] {
        case nil, .null?: return nil
        case .string(let raw)?: items = raw.split(separator: ",").map(String.init)
        case .array(let array)?:
            items = try array.map { item in
                switch item {
                case .string(let value): return value
                case .int(let value): return String(value)
                default: throw DeviceToolError(message: "\(key) must be a list of strings.")
                }
            }
        default: throw DeviceToolError(message: "\(key) must be a list of strings.")
        }
        let cleaned = items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : cleaned
    }

    func requiredStrings(_ key: String, _ hint: String) throws -> [String] {
        guard let items = try strings(key) else { throw DeviceToolError(message: "\(key) is required: \(hint).") }
        return items
    }

    func uuids(_ key: String, _ hint: String) throws -> [UUID] {
        let raw = try requiredStrings(key, hint)
        let invalid = raw.filter { UUID(uuidString: $0) == nil }
        guard invalid.isEmpty else {
            throw DeviceToolError(message: "\(invalid.map { "\"\($0)\"" }.joined(separator: ", ")) in \(key) \(invalid.count == 1 ? "isn't an id" : "aren't ids"). Use \(hint).")
        }
        return raw.compactMap(UUID.init(uuidString:))
    }
}
