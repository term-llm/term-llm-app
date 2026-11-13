import AppKit
import ComputerUseCore
import Foundation
import os

/// Paste through a promised item, then give the person their clipboard back unless
/// they copied something meanwhile. The app's request for data is our read receipt.
public final class Pasteboard: Sendable {
    public static let readTimeout = 2.0
    public static let landTimeout = 2.0, landPoll = 0.025
    public static let currentHostOnly = 1 // Never travel to the person's other devices.
    public static let restoreFile = "paste-restore.bin"
    public static let plain = "public.utf8-plain-text", html = "public.html", rtf = "public.rtf"
    private static let pasteLock = NSLock() // One paste at a time in the whole helper.
    public typealias Snapshot = [[String: Data]]

    /// Immutable concurrent dependencies. Fake hooks run synchronously on their
    /// caller (including the no-main-loop worker fallback). Native hooks alone
    /// cross the main-thread boundary; no SDK object is captured by a worker.
    public struct Backend: Sendable {
        public let snapshot: @Sendable () -> Snapshot
        public let write: @Sendable (LazyPasteData) -> Int?
        public let restore: @Sendable (Snapshot, Int) -> Bool
        public init(snapshot: @escaping @Sendable () -> Snapshot,
                    write: @escaping @Sendable (LazyPasteData) -> Int?,
                    restore: @escaping @Sendable (Snapshot, Int) -> Bool) {
            self.snapshot = snapshot; self.write = write; self.restore = restore
        }
        @MainActor
        public init(board: NSPasteboard) {
            let owner = NativeBoard(board)
            snapshot = { Self.onMain { Pasteboard.snapshot(owner.board) } ?? [] }
            write = { provider in Self.onMain { Pasteboard.write(owner.board, provider: provider) } ?? nil }
            restore = { saved, ours in Self.onMain { Pasteboard.restore(owner.board, saved: saved, ours: ours) } ?? false }
        }
        /// Factory remains callable from a helper worker. Without a running main
        /// loop it fails closed, rather than evaluating `.general` off main.
        public static func general() -> Backend {
            onMain { Backend(board: .general) } ?? Backend(snapshot: { [] }, write: { _ in nil }, restore: { _, _ in false })
        }
        // Shared native-only boundary, internal so fake-only tests can verify
        // fail-closed fallback without constructing a pasteboard or importing HTML.
        static func onMain<T: Sendable>(_ work: @MainActor () throws -> T) rethrows -> T? {
            try MainThread.callOnMain {
                guard Thread.isMainThread else { return nil }
                return try MainActor.assumeIsolated { try work() }
            }
        }
    }
    /// The SDK handle never leaves this actor-owned container. There is no
    /// unchecked Sendable promise for NSPasteboard or its item graph.
    @MainActor
    private final class NativeBoard {
        let board: NSPasteboard
        init(_ board: NSPasteboard) { self.board = board }
    }
    /// A wait must evaluate its predicate synchronously and must not store or
    /// reschedule it. `landed` can therefore remain operation-local, non-Sendable
    /// Actions state. The wait itself may be called by concurrent workers.
    public typealias Wait = @Sendable (() -> Bool, TimeInterval, TimeInterval) -> Bool
    private let board: @Sendable () -> Backend
    private let stateDirectory: @Sendable () -> URL
    private let wait: Wait
    public init(board: @escaping @Sendable () -> Backend = { Backend.general() },
                stateDirectory: @escaping @Sendable () -> URL = { Paths.stateDirectory() },
                wait: @escaping Wait = { Pasteboard.wait($0, timeout: $1, poll: $2) }) {
        self.board = board; self.stateDirectory = stateDirectory; self.wait = wait
    }
    public static func markdownHTML(_ text: String) -> String {
        // Headings, lists, paragraphs, bold, italic, code and links. No more.
        let escaped = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let separator = try! NSRegularExpression(pattern: "\\n\\s*\\n")
        let ns = escaped as NSString
        var blocks: [String] = [], start = 0
        for match in separator.matches(in: escaped, range: NSRange(location: 0, length: ns.length)) {
            blocks.append(ns.substring(with: NSRange(location: start, length: match.range.location - start))); start = NSMaxRange(match.range)
        }
        blocks.append(ns.substring(from: start))
        var body = blocks.map { block -> String in
            let heading = try! NSRegularExpression(pattern: "\\A(#{1,6}) +(.*)\\z")
            if let match = heading.firstMatch(in: block, range: NSRange(location: 0, length: (block as NSString).length)) {
                let ns = block as NSString, level = ns.substring(with: match.range(at: 1)).count
                return "<h\(level)>\(ns.substring(with: match.range(at: 2)))</h\(level)>"
            }
            let lines = block.components(separatedBy: "\n")
            for (pattern, tag) in [("^[-*] +", "ul"), ("^\\d+\\. +", "ol")] {
                if lines.allSatisfy({ $0.range(of: pattern, options: .regularExpression) != nil }) {
                    return "<\(tag)>" + lines.map { "<li>" + $0.replacingOccurrences(of: "^\\S+ +", with: "", options: .regularExpression) + "</li>" }.joined() + "</\(tag)>"
                }
            }
            return "<p>" + lines.joined(separator: "<br>") + "</p>"
        }.joined()
        for (pattern, replacement) in [("`([^`]+)`", "<code>$1</code>"), ("\\*\\*(.+?)\\*\\*", "<b>$1</b>"), ("(?<![*\\w])\\*(?=[^\\s*])(.+?)(?<=\\S)\\*", "<i>$1</i>"), ("\\[([^\\]]+)\\]\\(([^)\\s]+)\\)", "<a href=\"$2\">$1</a>")] {
            body = body.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return body
    }
    /// HTML import belongs on the main thread (AppKit); plain markdown stays the
    /// source as written, while HTML's plain representation is its rendered text.
    public static func representations(_ text: String, format: String) throws -> [String: Data] {
        guard format == "md" || format == "html" else { return [plain: Data(text.utf8)] }
        // Unlike MainThread's intentional fake/test fallback, AppKit HTML
        // importing must never run inline on a worker without a main loop.
        guard let made = try Backend.onMain({ try richRepresentations(text, format: format) }) else {
            throw Errors.make("paste_write_failed")
        }
        return made
    }
    @MainActor
    private static func richRepresentations(_ text: String, format: String) throws -> [String: Data] {
        let page = "<meta charset=\"utf-8\">" + (format == "md" ? markdownHTML(text) : text)
        let data = Data(page.utf8)
        guard let rich = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil),
              let rtfData = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]) else { throw Errors.make("paste_write_failed") }
        return [html: data, rtf: rtfData, plain: Data((format == "md" ? text : rich.string).utf8)]
    }
    @MainActor
    public static func snapshot(_ board: NSPasteboard) -> Snapshot {
        (board.pasteboardItems ?? []).map { item in
            var kinds: [String: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { kinds[type.rawValue] = data } }
            return kinds
        }
    }
    @MainActor
    public static func write(_ board: NSPasteboard, provider: LazyPasteData) -> Int? {
        let item = NSPasteboardItem()
        guard item.setDataProvider(provider, forTypes: provider.payload.keys.map { NSPasteboard.PasteboardType($0) }) else { return nil }
        board.prepareForNewContents(with: .currentHostOnly)
        return board.writeObjects([item]) ? board.changeCount : nil
    }
    @MainActor
    public static func restore(_ board: NSPasteboard, saved: Snapshot, ours: Int) -> Bool {
        guard board.changeCount == ours else { return false } // That change is the person's.
        board.clearContents()
        let items = saved.map { kinds -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (kind, data) in kinds { item.setData(data, forType: NSPasteboard.PasteboardType(kind)) }
            return item
        }
        if !items.isEmpty { _ = board.writeObjects(items) }
        return true
    }
    public static func wait(_ done: () -> Bool, timeout: TimeInterval, poll: TimeInterval = 0.01) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !done() {
            if ProcessInfo.processInfo.systemUptime >= deadline { return false }
            // The clipboard asks our item for data on the main thread. Keep its
            // run loop turning there; sleeping it would prevent the read receipt.
            if Thread.isMainThread { CFRunLoopRunInMode(.defaultMode, poll, false) }
            else { Thread.sleep(forTimeInterval: poll) }
        }
        return true
    }
    // Actions supplies pid-targeted Command-V and watches the focused field for
    // the optional landed predicate. No focus is changed by this primitive.
    // The global execution lock intentionally spans the entire transaction,
    // including native main hops. Hooks may inspect payload/receipt state, but
    // MUST NOT reenter paste/restoreSaved (even from a main-thread callback), or
    // wait for another paste: that would wait on this transaction's own lock.
    // Native helper transactions run on workers. Main must keep servicing their
    // hops, not block acquiring this lock behind an active worker transaction;
    // direct main-thread transactions require an otherwise idle paste executor.
    // The native main loop must not start/stop during paste or restoreSaved:
    // existing startup/shutdown ordering starts it before transactions and drains
    // transactions before stopping it. An unavailable native restore currently
    // maps to false (like a copy conflict), so cleanup deletes the recovery file.
    // Follow-up: distinguish unavailable from conflict with a restore status API;
    // lifecycle ordering must keep that unavailable-during-restore case unreachable.
    // No other lock spans a hook, a main hop, a sleep or filesystem work.
    public func paste(_ text: String, format: String, sendPasteKey: () throws -> Void,
                      timeout: TimeInterval = Pasteboard.readTimeout, landed: (() -> Bool)? = nil) throws {
        Self.pasteLock.lock(); defer { Self.pasteLock.unlock() }
        let backend = board()
        let provider = LazyPasteData(payload: try Self.representations(text, format: format))
        let saved = backend.snapshot()
        guard let ours = backend.write(provider) else { throw Errors.make("paste_write_failed") }
        let path = stateDirectory().appendingPathComponent(Self.restoreFile)
        var restored = false
        var failure: HarnessError?
        // Also restore on file-write failure (upstream's try starts after the save).
        // A disk error must not strand the person's clipboard in a running helper.
        do {
            try save(["count": ours, "items": saved], to: path)
            try sendPasteKey()
            if !wait({ provider.wasRead }, timeout, 0.01) { failure = Errors.make("paste_not_read") }
            else if let landed { _ = wait(landed, Self.landTimeout, Self.landPoll) }
        } catch {
            _ = backend.restore(saved, ours)
            try? FileManager.default.removeItem(at: path)
            throw error
        }
        restored = backend.restore(saved, ours)
        try? FileManager.default.removeItem(at: path)
        if !restored { throw Errors.make("paste_conflict") }
        if let failure { throw failure }
    }
    private func save(_ value: [String: Any], to path: URL) throws {
        try UnixSocket.makeOwnFolder(path.deletingLastPathComponent().path)
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        // Enforce 0600 even for an existing file; do not follow a symlink.
        let fd = open(path.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw WireError.system("open paste restore", errno) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        guard fchmod(fd, 0o600) == 0 else { throw WireError.system("chmod paste restore", errno) }
        try file.write(contentsOf: data)
    }
    /// A helper that died mid-paste left the clipboard in a file. A half-written
    /// file restores nothing; a newer copy by the person is never overwritten.
    // ComputerUseRuntime calls this before accepting requests, and on shutdown.
    public func restoreSaved() {
        Self.pasteLock.lock(); defer { Self.pasteLock.unlock() }
        let path = stateDirectory().appendingPathComponent(Self.restoreFile)
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        defer { try? FileManager.default.removeItem(at: path) }
        guard let data = try? Data(contentsOf: path),
              let left = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let items = left["items"] as? Snapshot, let count = left["count"] as? Int else { return }
        let backend = board()
        _ = backend.restore(items, count)
    }
}

public final class LazyPasteData: NSObject, NSPasteboardItemDataProvider, Sendable {
    public let payload: [String: Data]
    private let read = OSAllocatedUnfairLock(initialState: false)
    public var wasRead: Bool { read.withLock { $0 } }
    public init(payload: [String: Data]) { self.payload = payload }
    /// Internal fake-backend receipt seam. Production marks only after setData;
    /// constructing a provider, inspecting payload or writing a promise is not a read.
    func markRead() { read.withLock { $0 = true } }
    public func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        // SDK provider callbacks deliver a caller-local item on the main thread.
        // Do not dispatch or transfer that non-Sendable item to another owner.
        assert(Thread.isMainThread, "NSPasteboard provider callback is expected on main")
        item.setData(payload[type.rawValue] ?? Data(), forType: type)
        markRead()
    }
}
