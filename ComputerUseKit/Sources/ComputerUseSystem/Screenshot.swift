import AppKit
import ComputerUseCore
import Foundation
import ImageIO
import os

/// A window's own pixels at backing resolution, without its shadow. A covered
/// window still gives its pixels; our pointer and halo never appear in it.
public final class Screenshot: Sendable {
    public static let jpegQuality = 0.8
    public static let randomCharacters = 6
    public static let maxAge: TimeInterval = 3600
    public static let proofMax = 200
    public static let captureTimeout: TimeInterval = 2.0, toolTimeout: TimeInterval = 1.8
    public static let retryAfter: TimeInterval = 60
    public static let captureTool = "/usr/sbin/screencapture"
    public static let phases = ["Capture Screenshot", "Write Screenshot File"]
    /// Called on a worker thread, which a hung capture may keep.
    public typealias Source = @Sendable (UInt32, [UInt32]) -> CGImage?
    /// Dependencies may be called concurrently by capture workers.
    public typealias Runner = @Sendable (String, [String], TimeInterval) throws -> Void
    private static let log = Logger(subsystem: "com.termllm.app.computeruse", category: "screenshot")
    private let folder: URL
    private let stateDirectory: @Sendable () -> URL
    private let runner: Runner
    private let tool: String
    private let sources: [Source]?
    private let uptime: @Sendable () -> TimeInterval
    private let name: @Sendable (pid_t) -> String
    private let silentUntil = OSAllocatedUnfairLock<[Int: TimeInterval]>(initialState: [:])
    public init(folder: URL = Paths.screenshotDirectory(), stateDirectory: @escaping @Sendable () -> URL = { Paths.stateDirectory() },
                captureTool: String = Screenshot.captureTool, runner: @escaping Runner = { try Screenshot.run($0, arguments: $1, timeout: $2) },
                sources: [Source]? = nil, uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                appName: @escaping @Sendable (pid_t) -> String = { NSRunningApplication(processIdentifier: $0)?.localizedName ?? "Unknown" }) {
        self.folder = folder; self.stateDirectory = stateDirectory; self.tool = captureTool
        self.runner = runner; self.sources = sources; self.uptime = uptime; self.name = appName
    }
    public static func fileName(_ appName: String, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let hour = c.hour!
        let date = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        let clock = String(format: "%d.%02d.%02d %@", hour % 12 == 0 ? 12 : hour % 12, c.minute!, c.second!, hour < 12 ? "AM" : "PM")
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let tail = String((0..<randomCharacters).map { _ in alphabet.randomElement()! })
        return "\(appName) Screenshot \(date) at \(clock) \(tail).jpeg"
    }
    /// A printed proof path must have no spaces. If the state path has one, use
    /// the renamed hidden fallback under the real home, as upstream does.
    public func proofFolder() -> URL {
        let state = stateDirectory()
        return (state.path.contains(" ") ? Paths.homeDirectory().appendingPathComponent(".term-llm-computer", isDirectory: true) : state).appendingPathComponent("proof", isDirectory: true)
    }
    public func keep(_ path: String, appName: String, now: Date = Date()) throws -> String {
        var app = appName.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if app.isEmpty { app = "App" }
        let tail = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.components(separatedBy: " ").last!
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.dateFormat = "yyyy-MM-dd-HH.mm.ss"
        let folder = proofFolder()
        try UnixSocket.makeOwnFolder(folder.path)
        let kept = folder.appendingPathComponent("\(app)-\(date.string(from: now))-\(tail).jpeg")
        // copyfile overwrites an existing proof of the same capture, as upstream.
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        try data.write(to: kept)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: kept.path)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]).filter { $0.pathExtension == "jpeg" }.sorted { Self.modified($0) < Self.modified($1) }
        for old in files.prefix(max(0, files.count - Self.proofMax)) { try? FileManager.default.removeItem(at: old) }
        return kept.path
    }
    /// Run only the child capture tool. It takes ~80 ms versus 15 ms in-process,
    /// but is left isolated on purpose. Measured three times on macOS 27.0: an
    /// in-process window capture makes the capture service drop the connection;
    /// the system library reconnects thousands of times a second for as long as
    /// that process lives, and the call hangs in every other process meanwhile.
    /// A child can be ended. Do not replace this with CGWindowListCreateImage.
    public static func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw WireError.timedOut
        }
        // Only the file counts: exit 0 does not say one was written.
    }
    private func temporaryCapture(_ arguments: (URL) -> [String], read: (URL) -> CGImage?) -> CGImage? {
        guard (try? UnixSocket.makeOwnFolder(folder.path)) != nil else { return nil }
        // Not a hidden name: the tool refuses to write one, and still exits 0.
        let path = folder.appendingPathComponent("capture-\(UUID().uuidString.prefix(8).lowercased()).png")
        defer { try? FileManager.default.removeItem(at: path) }
        do { try runner(tool, arguments(path), Self.toolTimeout) } catch { return nil }
        guard let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else { return nil }
        return read(path)
    }
    public func toolImage(_ windowID: UInt32, extraIDs: [UInt32] = []) -> CGImage? {
        // Extra windows are captured separately and composed by capture(), rather
        // than passed to the tool. This mirrors upstream's unused extra_ids.
        temporaryCapture({ ["-x", "-o", "-l", String(windowID), $0.path] }) { path in
            guard let source = CGImageSourceCreateWithURL(path as CFURL, nil) else { return nil }
            // Decode now: the PNG file is removed as soon as this call returns.
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
    }
    /// One point is enough to preflight the child tool. Unlike this process's
    /// cached preflight it sees a grant given after the helper started immediately.
    public func canCapture() -> Bool {
        var exists = false
        _ = temporaryCapture({ ["-x", "-R0,0,1,1", $0.path] }) { _ in exists = true; return nil }
        return exists
    }
    public func firstImage(_ windowID: UInt32, extraIDs: [UInt32] = []) -> CGImage? {
        let sources = self.sources ?? [{ self.toolImage($0, extraIDs: $1) }]
        for (index, source) in sources.enumerated() {
            let until = silentUntil.withLock { $0[index] ?? 0 }
            if uptime() < until { continue }
            let result = OSAllocatedUnfairLock<CGImage?>(initialState: nil)
            let done = DispatchSemaphore(value: 0)
            // A capture can stay silent 40 s and then give nothing (measured).
            // Never hang a state read on its picture: stop waiting on the worker.
            DispatchQueue.global().async {
                let image = source(windowID, extraIDs)
                result.withLock { $0 = image }; done.signal()
            }
            let answered = done.wait(timeout: .now() + Self.captureTimeout) == .success
            if let image = result.withLock({ $0 }) { return image }
            // An answered nil (e.g. a minimized window) is tried next time. Only
            // a still-hanging call is left alone for a while.
            if !answered {
                // Injected code can reenter; no callback runs under the lock.
                let until = uptime() + Self.retryAfter
                // Concurrent timeouts can publish their clock samples out of order.
                silentUntil.withLock { $0[index] = max($0[index] ?? 0, until) }
            }
        }
        return nil
    }
    public static func writeJPEG(_ image: CGImage, path: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(path as CFURL, "public.jpeg" as CFString, 1, nil) else { throw Errors.make("screenshot_failed") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Errors.make("screenshot_failed") }
    }
    public static func composed(_ base: CGImage, frame: CGRect, extras: [(CGImage, CGRect)], scale: Double) throws -> (CGImage, CGPoint) {
        let frames = [frame] + extras.map { $0.1 }
        let left = frames.map(\.minX).min()!, top = frames.map(\.minY).min()!
        let right = frames.map(\.maxX).max()!, bottom = frames.map(\.maxY).max()!
        let width = Int(((right - left) * scale).rounded(.toNearestOrEven)), height = Int(((bottom - top) * scale).rounded(.toNearestOrEven))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { throw Errors.make("screenshot_failed") }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (image, rect) in [(base, frame)] + extras { // Back to front; the context counts up.
            context.draw(image, in: CGRect(x: (rect.minX - left) * scale, y: (bottom - rect.minY - rect.height) * scale, width: rect.width * scale, height: rect.height * scale))
        }
        guard let image = context.makeImage() else { throw Errors.make("screenshot_failed") }
        return (image, CGPoint(x: left, y: top))
    }
    public func capture(_ window: ComputerUseCore.WindowRef, extras: [(UInt32, CGRect)] = []) throws -> Shot {
        cleanup()
        var started = uptime()
        guard var image = firstImage(window.windowID) else { throw Errors.make("screenshot_failed") }
        guard image.width > 0, image.height > 0, window.frame.width > 0 else { throw Errors.make("screenshot_size", ["size": "(\(image.width), \(image.height))"]) }
        let scale = Double(image.width) / window.frame.width
        var origin = window.frame.origin
        let drawn = extras.compactMap { id, frame in firstImage(id).map { ($0, frame) } }
        if !drawn.isEmpty { (image, origin) = try Self.composed(image, frame: window.frame, extras: drawn, scale: scale) }
        let captureMS = (uptime() - started) * 1000
        Self.log.debug("\(Self.phases[0], privacy: .public): \(captureMS, format: .fixed(precision: 0)) ms")
        started = uptime()
        try UnixSocket.makeOwnFolder(folder.path)
        let path = folder.appendingPathComponent(Self.fileName(name(window.pid)))
        try Self.writeJPEG(image, path: path)
        let writeMS = (uptime() - started) * 1000
        Self.log.debug("\(Self.phases[1], privacy: .public): \(writeMS, format: .fixed(precision: 0)) ms")
        return Shot(path: path.path, scale: scale, origin: origin, width: image.width, height: image.height)
    }
    public func cleanup(maxAge: TimeInterval = Screenshot.maxAge, now: Date = Date()) {
        let oldest = now.addingTimeInterval(-maxAge)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files where file.pathExtension == "jpeg" || (file.lastPathComponent.hasPrefix("capture-") && file.pathExtension == "png") {
            if Self.modified(file) < oldest { try? FileManager.default.removeItem(at: file) } // Another call may remove it first.
        }
    }
    private static func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture }
}
