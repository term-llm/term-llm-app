import Foundation
import os

/// Listen diagnostics: `log stream --predicate 'subsystem == "com.termllm.app" && category == "listen"'`.
let listenLog = Logger(subsystem: "com.termllm.app", category: "listen")

/// Something to listen to: a podcast episode, audio term-llm generated, a
/// song file, or a video played for its sound. Kept on this phone in the
/// Listen library; the order of unplayed items is the Up Next queue.
struct ListenItem: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case episode, generated, music, sfx, video, audio
    }

    enum Status: String, Codable, CaseIterable, Sendable {
        /// Waiting in Up Next, never started.
        case unplayed
        /// Started; `position` is where to resume.
        case inProgress = "in_progress"
        /// Finished or marked played; kept in history.
        case played
        /// Put away without finishing; kept in history.
        case archived
    }

    enum Download: String, Codable, Sendable {
        case none, queued, downloading, downloaded, failed
    }

    let id: UUID
    var url: URL
    var title: String
    /// Show, author, voice, or artist.
    var artist: String?
    var album: String?
    var details: String?
    var artworkURL: URL?
    var kind: Kind
    var duration: TimeInterval?
    var publishedAt: Date?
    let addedAt: Date
    var updatedAt: Date
    var status: Status
    /// Resume position in seconds.
    var position: TimeInterval
    var lastPlayedAt: Date?
    var download: Download
    /// File name inside the downloads folder.
    var localFile: String?
    var downloadedBytes: Int64?
    var downloadError: String?

    init(id: UUID = UUID(), url: URL, title: String, artist: String? = nil, album: String? = nil,
         details: String? = nil, artworkURL: URL? = nil, kind: Kind = .audio, duration: TimeInterval? = nil,
         publishedAt: Date? = nil, addedAt: Date = Date(), status: Status = .unplayed, position: TimeInterval = 0) {
        self.id = id
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.details = details
        self.artworkURL = artworkURL
        self.kind = kind
        self.duration = duration
        self.publishedAt = publishedAt
        self.addedAt = addedAt
        self.updatedAt = addedAt
        self.status = status
        self.position = position
        self.download = .none
    }

    /// Still in Up Next.
    var isQueued: Bool { status == .unplayed || status == .inProgress }

    /// Speech benefits from spoken-audio routing and skip buttons.
    var isSpoken: Bool { kind == .episode || kind == .generated || kind == .audio || kind == .video }

    var subtitle: String {
        [artist, album].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }

    /// Where playback should start: the saved position, unless nearly done.
    func resumePosition() -> TimeInterval {
        guard status == .inProgress, position > 1 else { return 0 }
        if let duration, duration > 0, position >= duration - ListenItem.finishedMargin { return 0 }
        return position
    }

    /// Within this many seconds of the end counts as finished.
    static let finishedMargin: TimeInterval = 5
}

/// Metadata for a new item; anything missing is filled from the URL.
struct ListenDraft: Equatable, Sendable {
    var url: URL
    var title: String?
    var artist: String?
    var album: String?
    var details: String?
    var artworkURL: URL?
    var kind: ListenItem.Kind?
    var duration: TimeInterval?
    var publishedAt: Date?

    init(url: URL, title: String? = nil, artist: String? = nil, album: String? = nil, details: String? = nil,
         artworkURL: URL? = nil, kind: ListenItem.Kind? = nil, duration: TimeInterval? = nil, publishedAt: Date? = nil) {
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.details = details
        self.artworkURL = artworkURL
        self.kind = kind
        self.duration = duration
        self.publishedAt = publishedAt
    }

    var inferredKind: ListenItem.Kind {
        if let kind { return kind }
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v", "mov", "webm": return .video
        default: return .audio
        }
    }

    var inferredTitle: String {
        if let title, !title.isEmpty { return title }
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty || name == "/" ? (url.host() ?? "Audio") : name
    }
}

enum ListenError: LocalizedError, Equatable {
    case notFound(String)
    case nothingToPlay
    case invalidURL(String)
    case storageUnavailable(String)
    case downloadFailed(String)
    case playbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let reference): return "No item \"\(reference)\" in Listen. Use media_list for item ids."
        case .nothingToPlay: return "Nothing to play: Up Next is empty."
        case .invalidURL(let message): return message
        case .storageUnavailable(let reason): return reason
        case .downloadFailed(let message): return "Download failed: \(message)"
        case .playbackFailed(let message): return "Can't play this: \(message)"
        }
    }
}

/// Which server's cookies a request may carry, and how relative paths
/// resolve. Media from the connected term-llm server is behind its sign-in
/// cookie; any other host gets no cookies.
struct ListenServer: Equatable, Sendable {
    let base: URL

    var origin: String? { Self.origin(of: base) }

    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased() else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1)
        return "\(scheme)://\(host):\(port)"
    }

    func isSameOrigin(_ url: URL) -> Bool {
        guard let origin else { return false }
        return Self.origin(of: url) == origin
    }

    /// The configured server, read where `ContentView` saves it.
    static func current(defaults: UserDefaults = .standard) -> ListenServer? {
        guard let raw = defaults.string(forKey: "serverURL"), let url = ServerAddress.parse(raw) else { return nil }
        return ListenServer(base: url)
    }

    /// Turns what the agent passed into a playable URL. Accepts absolute
    /// http(s) URLs and paths on the connected server (`/media/…`).
    static func resolve(_ raw: String, server: ListenServer?) throws -> URL {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("term-llm-media://") {
            throw ListenError.invalidURL(
                "term-llm-media:// references can't be resolved on the iPhone yet. Pass the published media URL "
                + "(a /media/… path on this server) or any direct http(s) audio/video URL.")
        }
        if value.hasPrefix("/") && !value.hasPrefix("//") {
            guard let server, let url = URL(string: value, relativeTo: server.base)?.absoluteURL else {
                throw ListenError.invalidURL("\(value) is a server path, but no term-llm server is configured.")
            }
            return url
        }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host()?.isEmpty == false else {
            throw ListenError.invalidURL("\"\(value)\" isn't a playable URL. Use a direct http(s) audio or video URL or a /media/… path.")
        }
        if url.user != nil || url.password != nil {
            throw ListenError.invalidURL("URLs with credentials aren't accepted.")
        }
        return url
    }
}
