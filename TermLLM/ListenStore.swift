import Foundation
import Observation

/// Limits apply both to untrusted tools and older on-disk metadata. One year
/// permits long recordings without passing absurd values to AVFoundation/UI.
enum ListenMediaTime {
    static let maximum: TimeInterval = 365 * 24 * 60 * 60
    static func validDuration(_ value: TimeInterval) -> Bool { value.isFinite && value > 0 && value <= maximum }
    static func validPosition(_ value: TimeInterval) -> Bool { value.isFinite && value >= 0 && value <= maximum }
    static func seconds(_ value: TimeInterval) -> Int {
        guard value.isFinite else { return 0 }
        return Int(exactly: min(maximum, max(0, value)).rounded()) ?? 0
    }
}

/// The Listen library kept on this phone. Unplayed and in-progress items in
/// list order form Up Next; played and archived items stay as history until
/// cleared. Saved as JSON after every change, except playback positions,
/// which go to a small file of their own (see `setPosition`).
@MainActor
@Observable
final class ListenStore {
    enum Placement: String, CaseIterable, Sendable {
        /// Top of Up Next (the caller usually starts it).
        case now
        /// Right after `current`.
        case next
        /// Bottom of Up Next.
        case end
    }

    private(set) var items: [ListenItem] = []
    /// Set when the saved library can't be written; changes stay in memory.
    private(set) var notice: String?

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let positionsURL: URL
    @ObservationIgnored private let persistence: ListenPersistence
    @ObservationIgnored private var saveGeneration = 0
    @ObservationIgnored private let now: () -> Date
    static let formatVersion = 1
    /// History beyond this many items is dropped, oldest first.
    static let historyLimit = 200

    init(fileURL: URL = ListenStore.defaultFileURL, now: @escaping () -> Date = Date.init,
         persistenceQueue: DispatchQueue = DispatchQueue(label: "TermLLM.ListenPersistence", qos: .utility)) {
        self.fileURL = fileURL
        positionsURL = Self.positionsURL(for: fileURL)
        self.now = now
        persistence = ListenPersistence(fileURL: fileURL, positionsURL: positionsURL, queue: persistenceQueue)
        load()
    }

    nonisolated static var defaultFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "Listen/library.json")
    }

    /// Where positions recorded since the library was last saved are kept.
    nonisolated static func positionsURL(for library: URL) -> URL {
        library.deletingLastPathComponent().appending(path: library.deletingPathExtension().lastPathComponent + "-positions.json")
    }

    var upNext: [ListenItem] { items.filter(\.isQueued) }
    var history: [ListenItem] {
        items.filter { !$0.isQueued }.sorted { ($0.lastPlayedAt ?? $0.updatedAt) > ($1.lastPlayedAt ?? $1.updatedAt) }
    }

    func item(_ id: UUID) -> ListenItem? {
        items.first { $0.id == id }
    }

    /// Finds an item by id, or by case-insensitive exact title (newest first).
    func resolve(_ reference: String) throws -> ListenItem {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: trimmed), let item = item(id) { return item }
        let matches = items.filter { $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }
        if let match = matches.first(where: \.isQueued) ?? matches.first { return match }
        throw ListenError.notFound(trimmed)
    }

    /// Adds drafts at `placement`. A URL already in the library is moved
    /// there instead (and back into Up Next), with any new metadata applied.
    @discardableResult
    func add(_ drafts: [ListenDraft], placement: Placement, after current: UUID? = nil) -> [ListenItem] {
        var next = items
        var placed: [ListenItem] = []
        let date = now()
        for draft in drafts {
            if let index = next.firstIndex(where: { $0.url == draft.url && $0.sourceID == draft.sourceID }) {
                var existing = next.remove(at: index)
                Self.apply(draft, to: &existing)
                if !existing.isQueued {
                    existing.status = .unplayed
                    existing.position = 0
                }
                existing.updatedAt = date
                placed.append(existing)
            } else {
                var item = ListenItem(url: draft.url, title: draft.inferredTitle, addedAt: date)
                Self.apply(draft, to: &item)
                item.kind = draft.inferredKind
                placed.append(item)
            }
        }
        // Avoid duplicates if the same URL was given twice.
        var seen = Set<UUID>()
        placed = placed.filter { seen.insert($0.id).inserted }
        next.removeAll { seen.contains($0.id) }

        let insertAt: Int
        switch placement {
        case .now:
            insertAt = 0
        case .next:
            if let current, let index = next.firstIndex(where: { $0.id == current }) {
                insertAt = index + 1
            } else {
                insertAt = 0
            }
        case .end:
            insertAt = (next.lastIndex(where: \.isQueued).map { $0 + 1 }) ?? 0
        }
        next.insert(contentsOf: placed, at: insertAt)
        commit(next)
        return placed
    }

    func update(_ id: UUID, save: Bool = true, _ change: (inout ListenItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        change(&item)
        if let duration = item.duration, !ListenMediaTime.validDuration(duration) { item.duration = nil }
        if !ListenMediaTime.validPosition(item.position) { item.position = 0 }
        item.updatedAt = now()
        items[index] = item
        if save { persist() }
    }

    /// Records where playback of `id` is. Called regularly while playing, so
    /// it rewrites only a small file of the positions recorded since the
    /// library was last saved, never the whole library (show notes and
    /// history make that hundreds of KB). The next library save takes them in
    /// and deletes the small file.
    func setPosition(_ position: TimeInterval, for id: UUID) {
        guard ListenMediaTime.validPosition(position), let index = items.firstIndex(where: { $0.id == id }) else { return }
        let position = max(0, position)
        if items[index].position != position { items[index].position = position }
        persistence.setPosition(position, for: id)
    }

    func setStatus(_ ids: [UUID], _ status: ListenItem.Status) throws {
        try requireAll(ids)
        let date = now()
        let targets = Set(ids)
        func changed(_ original: ListenItem) -> ListenItem {
            var item = original
            item.status = status
            item.updatedAt = date
            if status == .played || status == .unplayed { item.position = 0 }
            if status == .played { item.lastPlayedAt = item.lastPlayedAt ?? date }
            return item
        }
        guard status == .unplayed else {
            commit(items.map { targets.contains($0.id) ? changed($0) : $0 })
            return
        }
        // Items brought back from history go to the end of Up Next; queued
        // ones keep their place.
        let returning = items.filter { targets.contains($0.id) && !$0.isQueued }.map(changed)
        var next = items.filter { !(targets.contains($0.id) && !$0.isQueued) }
            .map { targets.contains($0.id) ? changed($0) : $0 }
        next.insert(contentsOf: returning, at: (next.lastIndex(where: \.isQueued).map { $0 + 1 }) ?? 0)
        commit(next)
    }

    func remove(_ ids: [UUID]) throws {
        try requireAll(ids)
        commit(items.filter { !ids.contains($0.id) })
    }

    /// Moves one Up Next item to `index` within Up Next.
    func move(_ id: UUID, toUpNextIndex index: Int) throws {
        guard let item = item(id) else { throw ListenError.notFound(id.uuidString) }
        var queue = upNext.filter { $0.id != id }
        var moved = item
        if !moved.isQueued { moved.status = .unplayed; moved.position = 0 }
        queue.insert(moved, at: max(0, min(index, queue.count)))
        commit(queue + items.filter { !$0.isQueued && $0.id != id })
    }

    /// Drag-to-reorder in the Up Next list.
    func moveUpNext(from source: IndexSet, to destination: Int) {
        var queue = upNext
        queue.move(fromOffsets: source, toOffset: destination)
        commit(queue + items.filter { !$0.isQueued })
    }

    /// Removes history (played and archived) and returns what was removed.
    @discardableResult
    func clearHistory() -> [ListenItem] {
        let removed = items.filter { !$0.isQueued }
        commit(items.filter(\.isQueued))
        return removed
    }

    /// The Up Next item after `id`, or the first when `id` isn't queued.
    func upNext(after id: UUID?) -> ListenItem? {
        let queue = upNext
        guard let id, let index = queue.firstIndex(where: { $0.id == id }) else { return queue.first }
        return queue.indices.contains(index + 1) ? queue[index + 1] : nil
    }

    func upNext(before id: UUID) -> ListenItem? {
        let queue = upNext
        guard let index = queue.firstIndex(where: { $0.id == id }), index > 0 else { return nil }
        return queue[index - 1]
    }

    func persist() {
        saveGeneration += 1
        let generation = saveGeneration
        persistence.writeLibrary(items) { [weak self] error in
            Task { @MainActor in
                guard let self, self.saveGeneration == generation else { return }
                if let error {
                    self.notice = "\(Self.saveFailurePrefix) \(error)"
                } else if self.notice?.hasPrefix(Self.saveFailurePrefix) == true {
                    self.notice = nil
                }
            }
        }
    }

    /// A queue marker, not a main-thread wait. Also used to end a lifecycle
    /// background assertion after all previously enqueued writes finish.
    func whenPersistenceCompletes(_ completion: @escaping @Sendable () -> Void) {
        persistence.whenDrained(completion)
    }

    /// Only willTerminate may briefly wait for queued writes. The drain marker
    /// signals on the persistence queue itself, never via the blocked MainActor.
    @discardableResult
    func drainForTermination() -> Bool {
        let drained = DispatchSemaphore(value: 0)
        persistence.whenDrained { drained.signal() }
        return drained.wait(timeout: .now() + 1.5) == .success
    }

    func flushForTesting() async {
        await withCheckedContinuation { continuation in
            persistence.whenDrained { continuation.resume() }
        }
    }

    func dismissNotice() {
        notice = nil
    }

    // MARK: - Private

    private static let saveFailurePrefix = "Listen changes couldn't be saved:"

    private func requireAll(_ ids: [UUID]) throws {
        let known = Set(items.map(\.id))
        if let missing = ids.first(where: { !known.contains($0) }) { throw ListenError.notFound(missing.uuidString) }
    }

    private func commit(_ next: [ListenItem]) {
        var trimmed = next
        let past = trimmed.filter { !$0.isQueued }
        if past.count > Self.historyLimit {
            let keep = Set(past.sorted { ($0.lastPlayedAt ?? $0.updatedAt) > ($1.lastPlayedAt ?? $1.updatedAt) }
                .prefix(Self.historyLimit).map(\.id))
            trimmed.removeAll { !$0.isQueued && !keep.contains($0.id) }
        }
        items = trimmed
        persist()
    }

    private static func apply(_ draft: ListenDraft, to item: inout ListenItem) {
        item.sourceID = draft.sourceID
        if let title = draft.title, !title.isEmpty { item.title = title }
        if let artist = draft.artist { item.artist = artist }
        if let album = draft.album { item.album = album }
        if let details = draft.details { item.details = details }
        if let artworkURL = draft.artworkURL { item.artworkURL = artworkURL }
        if let kind = draft.kind { item.kind = kind }
        if let duration = draft.duration, ListenMediaTime.validDuration(duration) { item.duration = duration }
        if let publishedAt = draft.publishedAt { item.publishedAt = publishedAt }
    }

    /// Positions recorded after the library was last saved win over its own.
    private func loadPositions() {
        guard let data = try? Data(contentsOf: positionsURL) else { return }
        guard let stored = try? Self.decoder.decode(StoredPositions.self, from: data) else {
            listenLog.error("Listen positions file is unreadable; using the library's positions")
            return
        }
        for (key, position) in stored.positions {
            guard let id = UUID(uuidString: key), ListenMediaTime.validPosition(position),
                  let index = items.firstIndex(where: { $0.id == id }) else { continue }
            items[index].position = position
            persistence.seedPosition(position, for: id)
        }
    }

    private func load() {
        defer { loadPositions() }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return
        } catch {
            notice = "The Listen library can't be opened right now (\(error.localizedDescription))."
            return
        }
        guard let body = try? Self.decoder.decode(Body.self, from: data) else {
            let backup = fileURL.deletingLastPathComponent()
                .appending(path: "library-unreadable-\((Int(exactly: now().timeIntervalSince1970.rounded(.down)) ?? 0)).json")
            persistence.setAside(at: backup)
            notice = "The Listen library couldn't be read. It was kept as \(backup.lastPathComponent) and a new one started."
            return
        }
        var seen = Set<UUID>()
        items = body.items.compactMap(\.value).filter { seen.insert($0.id).inserted }
        for index in items.indices {
            if let duration = items[index].duration, !ListenMediaTime.validDuration(duration) { items[index].duration = nil }
            if !ListenMediaTime.validPosition(items[index].position) { items[index].position = 0 }
        }
        // A download interrupted by the app quitting won't finish.
        for index in items.indices where items[index].download == .downloading || items[index].download == .queued {
            items[index].download = .none
        }
    }

    private struct StoredPositions: Codable {
        let version: Int
        /// Seconds, by item id.
        let positions: [String: TimeInterval]
    }

    private struct Body: Decodable {
        let items: [Lossy<ListenItem>]
    }

    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Both library snapshots and position deltas use this one FIFO. Mutable state
/// and encoders live exclusively on the queue; the lock-free MainActor facade
/// only passes immutable Sendable snapshots. Normal and background saves never
/// wait synchronously; willTerminate alone uses a bounded 1.5-second drain.
private final class ListenPersistence: @unchecked Sendable {
    private let queue: DispatchQueue
    private let fileURL: URL
    private let positionsURL: URL
    private var positions: [String: TimeInterval] = [:]

    init(fileURL: URL, positionsURL: URL, queue: DispatchQueue) {
        self.queue = queue
        self.fileURL = fileURL
        self.positionsURL = positionsURL
    }

    func seedPosition(_ position: TimeInterval, for id: UUID) {
        queue.async { self.positions[id.uuidString] = position }
    }

    func setPosition(_ position: TimeInterval, for id: UUID) {
        queue.async {
            guard self.positions[id.uuidString] != position else { return }
            self.positions[id.uuidString] = position
            do {
                try self.write(StoredPositions(version: 1, positions: self.positions), to: self.positionsURL)
            } catch {
                listenLog.error("Listen position save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func writeLibrary(_ items: [ListenItem], completion: @escaping @Sendable (String?) -> Void) {
        queue.async {
            do {
                try self.write(Stored(version: 1, items: items), to: self.fileURL)
                // Only a successful write subsumes older position deltas. A
                // later delta is queued behind this removal and cannot be lost.
                self.positions = [:]
                try? FileManager.default.removeItem(at: self.positionsURL)
                completion(nil)
            } catch {
                listenLog.error("Listen library save failed: \(error.localizedDescription, privacy: .public)")
                completion(error.localizedDescription)
            }
        }
    }

    func setAside(at backup: URL) {
        queue.async { try? FileManager.default.moveItem(at: self.fileURL, to: backup) }
    }

    func whenDrained(_ completion: @escaping @Sendable () -> Void) { queue.async(execute: completion) }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private struct Stored: Encodable { let version: Int; let items: [ListenItem] }
    private struct StoredPositions: Encodable { let version: Int; let positions: [String: TimeInterval] }
}
