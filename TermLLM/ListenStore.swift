import Foundation
import Observation

/// The Listen library kept on this phone. Unplayed and in-progress items in
/// list order form Up Next; played and archived items stay as history until
/// cleared. Saved as JSON after every change.
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
    @ObservationIgnored private let now: () -> Date
    static let formatVersion = 1
    /// History beyond this many items is dropped, oldest first.
    static let historyLimit = 200

    init(fileURL: URL = ListenStore.defaultFileURL, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        load()
    }

    nonisolated static var defaultFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "Listen/library.json")
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
        item.updatedAt = now()
        items[index] = item
        if save { persist() }
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
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Self.encoder.encode(Stored(version: Self.formatVersion, items: items))
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            if notice?.hasPrefix(Self.saveFailurePrefix) == true { notice = nil }
        } catch {
            listenLog.error("Listen library save failed: \(error.localizedDescription, privacy: .public)")
            notice = "\(Self.saveFailurePrefix) \(error.localizedDescription)"
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
        if let duration = draft.duration, duration > 0 { item.duration = duration }
        if let publishedAt = draft.publishedAt { item.publishedAt = publishedAt }
    }

    private func load() {
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
                .appending(path: "library-unreadable-\(Int(now().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            notice = "The Listen library couldn't be read. It was kept as \(backup.lastPathComponent) and a new one started."
            return
        }
        var seen = Set<UUID>()
        items = body.items.compactMap(\.value).filter { seen.insert($0.id).inserted }
        // A download interrupted by the app quitting won't finish.
        for index in items.indices where items[index].download == .downloading || items[index].download == .queued {
            items[index].download = .none
        }
    }

    private struct Stored: Encodable {
        let version: Int
        let items: [ListenItem]
    }

    private struct Body: Decodable {
        let items: [Lossy<ListenItem>]
    }

    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
