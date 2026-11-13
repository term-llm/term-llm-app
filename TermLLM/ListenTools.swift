import Foundation

/// The agent's media tools. They share the Listen library and player with the
/// mini player and Listen screen, so the agent's changes show up immediately.
/// Items can be referred to by id or exact title.
@MainActor
final class ListenTools {
    private unowned let listen: Listen
    private let source: ListenServer?
    private let platform: DeviceToolPlatform

    init(listen: Listen, source: ListenServer? = nil, platform: DeviceToolPlatform = .current) {
        self.platform = platform
        self.source = source
        self.listen = listen
    }

    private var store: ListenStore { listen.store }
    private var player: ListenPlayer { listen.player }

    static let kinds = ListenItem.Kind.allCases.map(\.rawValue)
    static let placements = ListenStore.Placement.allCases.map(\.rawValue)
    static let downloads = Listen.DownloadPolicy.allCases.map(\.rawValue)
    static let controlActions = ["pause", "resume", "stop", "seek", "skip", "next", "previous", "rate", "sleep",
                                 "sleep_at_end", "cancel_sleep", "hide_player", "show_player"]
    static let manageActions = ["remove", "mark_played", "mark_unplayed", "archive", "move", "clear_history",
                                "download", "cancel_download", "delete_download"]

    var tools: [DeviceTool] {
        [
            tool("media_add",
                 "Add audio or video to the Listen queue on the \(platform.name) (podcast episodes, audio term-llm generated, songs, "
                 + "sound effects, videos played for their sound). Each url must point at the media file itself (mp3, m4a, "
                 + "wav, mp4, …), not a web page: any http(s) URL, or a /media/… path on this term-llm server. Give a good "
                 + "title and artist (show, voice, or author): they appear \(platform == .mac ? "in Now Playing" : "on the lock screen"). position: now starts playing "
                 + "it, next plays after the current item, end (default) adds to the bottom of Up Next. A URL already in the "
                 + "library is moved instead of duplicated.",
                 itemsSchema(),
                 { try await $0.add($1) }),
            tool("media_list",
                 "List the Listen library on the \(platform.name): Up Next in play order (default), history (played or archived), "
                 + "or all, with item ids, progress, and download state.",
                 schema(["filter": .enumeration(["up_next", "history", "all"], "Which items. Default up_next."),
                         "limit": .integer("Maximum items, 1–50. Default 20.")]),
                 readOnly: true) { tools, args in try tools.list(args) },
            tool("media_play",
                 "Play an item from the Listen library on the \(platform.name), resuming where it was left. Without item, resumes "
                 + "the current item or starts Up Next.",
                 schema(["item": .string("Item id (from media_list or media_add) or exact title."),
                         "start_at": .number("Start this many seconds in, instead of resuming.")]),
                 { try await $0.play($1) }),
            tool("media_control",
                 "Control Listen playback on the \(platform.name): pause, resume, stop, seek (to seconds), skip (by seconds, "
                 + "negative goes back), next, previous, rate (speed 0.5–3), sleep (pause after minutes; 0 cancels), "
                 + "sleep_at_end (pause when this item ends), cancel_sleep, hide_player/show_player (the mini player bar).",
                 schema(["action": .enumeration(Self.controlActions, "What to do."),
                         "seconds": .number("For seek (position) or skip (amount)."),
                         "rate": .number("For rate: playback speed, e.g. 1.5."),
                         "minutes": .integer("For sleep.")],
                        required: ["action"]),
                 { try await $0.control($1) }),
            tool("media_now_playing",
                 "What Listen is playing on the \(platform.name): the item, position, duration, time left, speed, state, sleep "
                 + "timer, and the next item. Use it to know what the user has heard.",
                 schema([:]), readOnly: true) { tools, _ in tools.nowPlaying() },
            tool("media_manage",
                 "Manage Listen items on the \(platform.name): remove, mark_played, mark_unplayed (back to Up Next), archive, "
                 + "move (to Up Next position to_index, 0 = top), clear_history (remove all played/archived), "
                 + "download (keep on the \(platform == .mac ? "Mac" : "phone") for offline play), cancel_download, delete_download.",
                 schema(["action": .enumeration(Self.manageActions, "What to do."),
                         "items": .array("Item ids or exact titles. Not needed for clear_history."),
                         "to_index": .integer("For move: position in Up Next, 0 = top.")],
                        required: ["action"]),
                 { try await $0.manage($1) }),
        ]
    }

    // MARK: - Tools

    private func add(_ args: Arguments) async throws -> JSONValue {
        let entries = try args.objects("items") ?? [args]
        let server = source ?? listen.server()
        let drafts = try entries.enumerated().map { index, entry in
            let label = entries.count > 1 ? "items[\(index)]." : ""
            guard let raw = try entry.optionalString("url") else {
                throw DeviceToolError(message: "\(label)url is required: a direct http(s) audio/video URL or a /media/… path.")
            }
            let url: URL
            do {
                url = try ListenServer.resolve(raw, server: server)
            } catch {
                throw DeviceToolError(message: "\(label)url: \(error.localizedDescription)")
            }
            return ListenDraft(
                url: url,
                title: try entry.optionalString("title"),
                artist: try entry.optionalString("artist"),
                album: try entry.optionalString("album"),
                details: try entry.optionalString("description"),
                artworkURL: try entry.optionalString("artwork_url").map {
                    do { return try ListenServer.resolve($0, server: server) } catch {
                        throw DeviceToolError(message: "\(label)artwork_url: \(error.localizedDescription)")
                    }
                },
                kind: try kind(entry, label: label),
                duration: try entry.double("duration_seconds"),
                publishedAt: try entry.optionalString("published_at").flatMap(Self.date),
                sourceID: server.flatMap { HubNavigation.isWithinMount(url, server: $0.base) ? $0.sourceID : nil }
            )
        }
        let placement = try choice(args, "position", ListenStore.Placement.self, default: .end)
        let download = try choice(args, "download", Listen.DownloadPolicy.self, default: .auto)
        var result: [String: JSONValue] = [:]
        do {
            let added = try await listen.add(drafts, placement: placement, download: download, origin: server)
            result["added"] = .array(added.map(Self.item))
        } catch {
            throw DeviceToolError(message: "Added, but playback failed: \(error.localizedDescription)")
        }
        result["up_next_count"] = .int(store.upNext.count)
        result["now_playing"] = nowPlaying()
        return .object(result)
    }

    private func list(_ args: Arguments) throws -> JSONValue {
        let limit = max(1, min(50, try args.int("limit") ?? 20))
        let filter = try args.optionalString("filter")?.lowercased() ?? "up_next"
        let items: [ListenItem]
        switch filter {
        case "up_next", "upnext", "queue": items = store.upNext
        case "history", "played": items = store.history
        case "all": items = store.upNext + store.history
        default: throw DeviceToolError(message: "Unknown filter \"\(filter)\". Use up_next, history, or all.")
        }
        var result: [String: JSONValue] = [
            "filter": .string(filter),
            "total": .int(items.count),
            "items": .array(items.prefix(limit).map(Self.item)),
            "downloads_bytes": .int(Int(listen.downloader.totalBytes)),
        ]
        if let current = player.currentID { result["current_id"] = .string(current.uuidString) }
        return .object(result)
    }

    private func play(_ args: Arguments) async throws -> JSONValue {
        let start = try args.double("start_at")
        if let reference = try args.optionalString("item") {
            let item = try store.resolve(reference)
            try await player.play(item.id, from: start)
        } else if let start, let current = player.currentID {
            try await player.play(current, from: start)
        } else {
            try await player.resume()
        }
        return nowPlaying()
    }

    private func control(_ args: Arguments) async throws -> JSONValue {
        let valid = "one of \(Self.controlActions.joined(separator: ", "))"
        switch try args.string("action", valid).lowercased() {
        case "pause": player.pause()
        case "resume", "play": try await player.resume()
        case "stop": player.stop()
        case "seek":
            guard let seconds = try args.double("seconds") else { throw DeviceToolError(message: "seek needs seconds (the position).") }
            try requireCurrent()
            await player.seek(to: seconds)
        case "skip":
            try requireCurrent()
            await player.skip(by: try args.double("seconds") ?? 30)
        case "next": try await player.next()
        case "previous", "back": try await player.previous()
        case "rate", "speed":
            guard let rate = try args.double("rate") else { throw DeviceToolError(message: "rate needs rate, e.g. 1.5.") }
            player.setRate(Float(rate))
        case "sleep": player.sleep(minutes: try args.int("minutes") ?? 0)
        case "sleep_at_end": player.sleepAtEndOfItem()
        case "cancel_sleep": player.cancelSleepTimer()
        case "hide_player": player.hideBar()
        case "show_player": player.showBar()
        case let action: throw DeviceToolError(message: "Unknown action \"\(action)\". Use \(valid).")
        }
        return nowPlaying()
    }

    private func nowPlaying() -> JSONValue {
        var result: [String: JSONValue] = [
            "state": .string(Self.state(player.status)),
            "rate": .double(Double(player.rate)),
            "player_visible": .bool(player.showsBar),
            "up_next_count": .int(store.upNext.count),
        ]
        if let item = player.current {
            result["item"] = Self.item(item)
            result["position_s"] = .int(Int(player.position.rounded()))
            if let duration = player.duration ?? item.duration {
                result["duration_s"] = .int(Int(duration.rounded()))
                result["remaining_s"] = .int(max(0, Int((duration - player.position).rounded())))
            }
            result["source"] = .string(player.streaming ? "stream" : "file")
            if player.buffering { result["buffering"] = true }
            if let until = player.bufferedUntil {
                result["buffered_ahead_s"] = .int(max(0, Int((until - player.position).rounded())))
            }
            if let progress = listen.downloader.progress[item.id] {
                result["download_received_bytes"] = .int(Int(progress.received))
                if let fraction = progress.fraction { result["download_percent"] = .int(Int(fraction * 100)) }
            }
            if let following = store.upNext(after: item.id) { result["next"] = Self.item(following) }
        } else if let first = store.upNext.first {
            result["next"] = Self.item(first)
        }
        if let sleepAt = player.sleepAt { result["sleep_at"] = .string(Self.iso.string(from: sleepAt)) }
        if player.sleepAtEnd { result["sleep_at_end"] = true }
        return .object(result)
    }

    private func manage(_ args: Arguments) async throws -> JSONValue {
        let valid = "one of \(Self.manageActions.joined(separator: ", "))"
        let action = try args.string("action", valid).lowercased()
        if action == "clear_history" {
            let count = store.history.count
            listen.clearHistory()
            return ["removed": .int(count), "up_next_count": .int(store.upNext.count)]
        }
        guard Self.manageActions.contains(action) else {
            throw DeviceToolError(message: "Unknown action \"\(action)\". Use \(valid).")
        }
        let references = try args.requiredStrings("items", "item ids from media_list, or exact titles")
        let ids = try references.map { try store.resolve($0).id }
        switch action {
        case "remove": try listen.remove(ids)
        case "mark_played": try await listen.finish(ids, as: .played)
        case "archive": try await listen.finish(ids, as: .archived)
        case "mark_unplayed": try store.setStatus(ids, .unplayed)
        case "move":
            guard ids.count == 1 else { throw DeviceToolError(message: "move takes one item.") }
            try store.move(ids[0], toUpNextIndex: try args.int("to_index") ?? 0)
        case "download": ids.forEach { listen.downloader.download($0) }
        case "cancel_download": ids.forEach(listen.downloader.cancel)
        case "delete_download": ids.forEach(listen.downloader.deleteFile)
        default: break
        }
        let remaining = ids.compactMap(store.item)
        return ["action": .string(action), "items": .array(remaining.map(Self.item)),
                "up_next_count": .int(store.upNext.count)]
    }

    // MARK: - Helpers

    private func requireCurrent() throws {
        guard player.currentID != nil else { throw DeviceToolError(message: "Nothing is playing. Use media_play first.") }
    }

    private func kind(_ args: Arguments, label: String) throws -> ListenItem.Kind? {
        guard let raw = try args.optionalString("kind") else { return nil }
        guard let kind = ListenItem.Kind(rawValue: raw.lowercased()) else {
            throw DeviceToolError(message: "\(label)kind must be one of \(Self.kinds.joined(separator: ", ")).")
        }
        return kind
    }

    private func choice<Choice: RawRepresentable & CaseIterable>(_ args: Arguments, _ key: String, _: Choice.Type,
                                                                 default fallback: Choice) throws -> Choice
        where Choice.RawValue == String {
        guard let raw = try args.optionalString(key) else { return fallback }
        guard let value = Choice(rawValue: raw.lowercased()) else {
            throw DeviceToolError(message: "\(key) must be one of \(Choice.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return value
    }

    private static let iso = ISO8601DateFormatter()

    private static func date(_ raw: String) -> Date? {
        if let date = iso.date(from: raw) { return date }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: raw)
    }

    static func item(_ item: ListenItem) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(item.id.uuidString),
            "title": .string(item.title),
            "kind": .string(item.kind.rawValue),
            "status": .string(item.status.rawValue),
            "url": .string(item.url.absoluteString),
            "download": .string(item.download.rawValue),
        ]
        if let artist = item.artist { object["artist"] = .string(artist) }
        if let album = item.album { object["album"] = .string(album) }
        if let duration = item.duration { object["duration_s"] = .int(Int(duration.rounded())) }
        if item.position > 0 { object["position_s"] = .int(Int(item.position.rounded())) }
        if let details = item.details { object["description"] = .string(String(details.prefix(280))) }
        if let error = item.downloadError, item.download == .failed { object["download_error"] = .string(error) }
        return .object(object)
    }

    private static func state(_ status: ListenPlayer.Status) -> String {
        switch status {
        case .idle: return "idle"
        case .loading: return "loading"
        case .playing: return "playing"
        case .paused: return "paused"
        case .failed(let message): return "failed: \(message)"
        }
    }

    // MARK: - Schemas

    private func itemsSchema() -> JSONValue {
        let item: [String: Parameter] = [
            "url": .string("Direct http(s) URL of the audio/video file, or a /media/… path on this term-llm server."),
            "title": .string("Title for \(platform == .mac ? "Now Playing" : "the lock screen") and queue."),
            "artist": .string("Show, author, voice, or artist."),
            "album": .string("Podcast or collection name."),
            "description": .string("Episode notes or what the audio contains."),
            "artwork_url": .string("Image URL for \(platform == .mac ? "Now Playing" : "the lock screen")."),
            "kind": .enumeration(Self.kinds, "What it is. Default from the file type."),
            "duration_seconds": .number("Length if known."),
            "published_at": .string("ISO 8601 date if known."),
        ]
        var properties = item.mapValues(\.json)
        properties["items"] = [
            "type": "array",
            "description": "Several items, in play order. Or give one item's fields at the top level.",
            "items": ["type": "object", "properties": .object(item.mapValues(\.json)),
                      "required": ["url"], "additionalProperties": false],
        ]
        properties["position"] = Parameter.enumeration(Self.placements, "now plays it; next after the current item; end (default).").json
        properties["download"] = Parameter.enumeration(Self.downloads, "auto (default): download this server's media, stream others; now; never.").json
        return ["type": "object", "properties": .object(properties), "required": [], "additionalProperties": false]
    }

    private enum Parameter {
        case string(String), integer(String), number(String), array(String), enumeration([String], String)

        var json: JSONValue {
            switch self {
            case .string(let description): return ["type": "string", "description": .string(description)]
            case .integer(let description): return ["type": "integer", "description": .string(description)]
            case .number(let description): return ["type": "number", "description": .string(description)]
            case .array(let description):
                return ["type": "array", "items": ["type": "string"], "description": .string(description)]
            case .enumeration(let values, let description):
                return ["type": "string", "enum": .array(values.map(JSONValue.string)), "description": .string(description)]
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

    private func tool(_ name: String, _ description: String, _ schema: JSONValue, readOnly: Bool = false,
                      _ run: @escaping @MainActor (ListenTools, Arguments) async throws -> JSONValue) -> DeviceTool {
        DeviceTool(name: name, description: description, inputSchema: schema, readOnly: readOnly) { [weak self] arguments in
            guard let self else { throw DeviceToolError(message: "Listen is unavailable.") }
            do {
                let result = try await run(self, Arguments(arguments))
                return DeviceToolResult(text: String(decoding: result.encoded(), as: UTF8.self))
            } catch let error as DeviceToolError {
                throw error
            } catch {
                throw DeviceToolError(message: error.localizedDescription)
            }
        }
    }
}
