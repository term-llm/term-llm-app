import AppKit
import ComputerUseCore
import Foundation

/// Paste through a promised item, then give the person their clipboard back unless
/// they copied something meanwhile. The app's request for data is our read receipt.
public final class Pasteboard {
    public static let readTimeout = 2.0
    public static let landTimeout = 2.0, landPoll = 0.025
    public static let currentHostOnly = 1 // Never travel to the person's other devices.
    public static let restoreFile = "paste-restore.bin"
    public static let plain = "public.utf8-plain-text", html = "public.html", rtf = "public.rtf"
    private static let pasteLock = NSLock() // One paste at a time in the whole helper.
    public typealias Snapshot = [[String: Data]]

    public struct Backend {
        public var snapshot: () -> Snapshot
        public var write: (LazyPasteData) -> Int?
        public var restore: (Snapshot, Int) -> Bool
        public init(snapshot: @escaping () -> Snapshot, write: @escaping (LazyPasteData) -> Int?, restore: @escaping (Snapshot, Int) -> Bool) {
            self.snapshot = snapshot; self.write = write; self.restore = restore
        }
        public init(board: NSPasteboard) {
            snapshot = { Pasteboard.snapshot(board) }
            write = { Pasteboard.write(board, provider: $0) }
            restore = { Pasteboard.restore(board, saved: $0, ours: $1) }
        }
    }
    private let board: () -> Backend
    private let stateDirectory: () -> URL
    private let wait: (@escaping () -> Bool, TimeInterval, TimeInterval) -> Bool
    public init(board: @escaping () -> Backend = { Backend(board: .general) },
                stateDirectory: @escaping () -> URL = { Paths.stateDirectory() },
                wait: @escaping (@escaping () -> Bool, TimeInterval, TimeInterval) -> Bool = Pasteboard.wait) {
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
        let page = "<meta charset=\"utf-8\">" + (format == "md" ? markdownHTML(text) : text)
        let data = Data(page.utf8)
        guard let rich = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil),
              let rtfData = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]) else { throw Errors.make("paste_write_failed") }
        return [html: data, rtf: rtfData, plain: Data((format == "md" ? text : rich.string).utf8)]
    }
    public static func snapshot(_ board: NSPasteboard) -> Snapshot {
        (board.pasteboardItems ?? []).map { item in
            var kinds: [String: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { kinds[type.rawValue] = data } }
            return kinds
        }
    }
    public static func write(_ board: NSPasteboard, provider: LazyPasteData) -> Int? {
        let item = NSPasteboardItem()
        guard item.setDataProvider(provider, forTypes: provider.payload.keys.map { NSPasteboard.PasteboardType($0) }) else { return nil }
        board.prepareForNewContents(with: .currentHostOnly)
        return board.writeObjects([item]) ? board.changeCount : nil
    }
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
    public static func wait(_ done: @escaping () -> Bool, timeout: TimeInterval, poll: TimeInterval = 0.01) -> Bool {
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
    public func paste(_ text: String, format: String, sendPasteKey: () throws -> Void,
                      timeout: TimeInterval = Pasteboard.readTimeout, landed: (() -> Bool)? = nil) throws {
        Self.pasteLock.lock(); defer { Self.pasteLock.unlock() }
        let backend = board()
        let provider = LazyPasteData(payload: try MainThread.callOnMain { try Self.representations(text, format: format) })
        let saved = MainThread.callOnMain { backend.snapshot() }
        guard let ours = MainThread.callOnMain({ backend.write(provider) }) else { throw Errors.make("paste_write_failed") }
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
            _ = MainThread.callOnMain { backend.restore(saved, ours) }
            try? FileManager.default.removeItem(at: path)
            throw error
        }
        restored = MainThread.callOnMain { backend.restore(saved, ours) }
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
        _ = MainThread.callOnMain { backend.restore(items, count) }
    }
}

public final class LazyPasteData: NSObject, NSPasteboardItemDataProvider {
    public let payload: [String: Data]
    private let lock = NSLock()
    private var read = false
    public var wasRead: Bool { lock.lock(); defer { lock.unlock() }; return read }
    public init(payload: [String: Data]) { self.payload = payload }
    public func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        item.setData(payload[type.rawValue] ?? Data(), forType: type)
        lock.lock(); read = true; lock.unlock()
    }
}
