import CryptoKit
import Foundation
import ImageIO
#if os(iOS)
import UIKit
#endif
import UniformTypeIdentifiers

/// Artwork kept on the phone, for Listen and (in a folder of its own, see
/// `music`) Apple Music. Each image is fetched once, saved at lock-screen
/// size in Application Support (not backed up), and read from that file from
/// then on, across launches; the file goes when nothing uses it. Views decode
/// it at the size they show. Server artwork is fetched with its owner's
/// cookies, like the media; other hosts never get cookies.
@MainActor
final class ListenArtworkStore {
    /// Saved images are at most this many pixels on the longer side: plenty
    /// for the lock screen and CarPlay.
    nonisolated static let savedPixels = 1024
    /// Decoded sizes, so the mini player and list rows share one.
    nonisolated static let sizes = [160, 320, 800]
    /// An image that couldn't be fetched isn't tried again for this long.
    static let retryDelay: Duration = .seconds(60)

    let directory: URL
    /// Nil: nothing here is ever fetched with cookies.
    private let cookies: ListenCookieJar?
    private let server: () -> ListenServer?
    private let session: URLSession
    private let images = NSCache<NSString, PlatformImage>()
    private let fileQueue: DispatchQueue
    /// Known files can be returned without joining utility cleanup work.
    private var saved: Set<String> = []
    private var fileReads: [String: Int] = [:]
    private var loads: [String: Task<URL?, Never>] = [:]
    private var failures: [String: ContinuousClock.Instant] = [:]

    init(directory: URL = ListenArtworkStore.defaultDirectory, cookies: ListenCookieJar?,
         server: @escaping () -> ListenServer?, session: URLSession = ListenMediaSession.shared,
         fileQueue: DispatchQueue = DispatchQueue(label: "TermLLM.ListenArtworkFiles", qos: .utility)) {
        self.directory = directory
        self.cookies = cookies
        self.server = server
        self.session = session
        self.fileQueue = fileQueue
        images.totalCostLimit = 32 << 20
    }

    nonisolated static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Listen/Artwork", directoryHint: .isDirectory)
    }

    /// The decoded size for `points` on a `scale` display.
    nonisolated static func pixels(for points: CGFloat, scale: CGFloat) -> Int {
        let needed = Int((points * max(1, scale)).rounded(.up))
        return sizes.first { $0 >= needed } ?? needed
    }

    /// The saved file's name for `item`'s artwork. The item's connection is
    /// part of the key, so one connection's image never shows for another's
    /// item. (Cheap: views ask on every update.)
    func fileName(for item: ListenItem) -> String? {
        item.artworkURL.map { fileName(url: $0, owner: item.sourceID) }
    }

    /// The saved file's name for artwork at `url` owned by connection `owner`
    /// (nil for public artwork).
    func fileName(url: URL, owner: UUID?) -> String {
        let digest = SHA256.hash(data: Data("\(owner?.uuidString ?? "public") \(url.absoluteString)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined() + ".img"
    }

    /// `item`'s artwork as a file on the phone, fetched the first time.
    func file(for item: ListenItem) async -> URL? {
        guard let url = item.artworkURL else { return nil }
        return await file(url: url, owner: item.sourceID, credentialed: isSameServer(item, url))
    }

    /// `credentialed` fetches the image with `owner`'s cookies.
    private func file(url: URL, owner: UUID?, credentialed: Bool) async -> URL? {
        let name = fileName(url: url, owner: owner)
        let destination = directory.appending(path: name)
        if saved.contains(name) { return destination }
        fileReads[name, default: 0] += 1
        defer {
            fileReads[name, default: 0] -= 1
            if fileReads[name] == 0 { fileReads[name] = nil }
        }
        // Ordered after pruning and before any subsequent save. No directory
        // scans, image writes or existence checks block MainActor.
        let exists = await withCheckedContinuation { continuation in
            fileQueue.async {
                continuation.resume(returning: FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
            }
        }
        if exists {
            saved.insert(name)
            return destination
        }
        if let load = loads[name] { return await load.value }
        if let failed = failures[name], ContinuousClock.now - failed < Self.retryDelay { return nil }
        let cookies = credentialed ? self.cookies : nil
        let directory = directory
        let load = Task { [weak self] () -> URL? in
            guard let self else { return nil }
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.httpShouldHandleCookies = false
            if let cookies {
                HTTPCookie.requestHeaderFields(with: await cookies.cookies(for: url, sourceID: owner)).forEach {
                    request.setValue($1, forHTTPHeaderField: $0)
                }
            }
            guard let (data, response) = try? await self.session.data(for: request),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
            return await withCheckedContinuation { continuation in
                self.fileQueue.async {
                    continuation.resume(returning: ListenArtworkStore.save(data, to: destination, in: directory))
                }
            }
        }
        loads[name] = load
        let file = await load.value
        loads[name] = nil
        if file != nil {
            saved.insert(name)
            failures[name] = nil
        } else {
            failures[name] = .now
        }
        return file
    }

    /// `item`'s artwork file, if it's on the phone already.
    func savedFile(for item: ListenItem) -> URL? {
        fileName(for: item).flatMap(savedFile(named:))
    }

    /// The public artwork at `url`, if it's on the phone already.
    func savedFile(url: URL) -> URL? {
        savedFile(named: fileName(url: url, owner: nil))
    }

    /// `item`'s artwork decoded at `pixels`, from its file.
    func image(for item: ListenItem, pixels: Int) async -> PlatformImage? {
        guard let url = item.artworkURL else { return nil }
        return await image(url: url, owner: item.sourceID, credentialed: isSameServer(item, url), pixels: pixels)
    }

    /// Public artwork at `url` (Apple Music) decoded at `pixels`; never
    /// fetched with cookies.
    func image(url: URL, pixels: Int) async -> PlatformImage? {
        await image(url: url, owner: nil, credentialed: false, pixels: pixels)
    }

    /// Already decoded at `pixels`, without waiting.
    func cachedImage(for item: ListenItem, pixels: Int) -> PlatformImage? {
        fileName(for: item).flatMap { images.object(forKey: Self.key($0, pixels)) }
    }

    func cachedImage(url: URL, pixels: Int) -> PlatformImage? {
        images.object(forKey: Self.key(fileName(url: url, owner: nil), pixels))
    }

    /// Deletes saved images none of `items` uses.
    func prune(keeping items: [ListenItem]) {
        prune(keepingNames: Set(items.compactMap(fileName(for:))))
    }

    /// Deletes saved public images other than those at `urls`.
    func prune(keepingURLs urls: [URL]) {
        prune(keepingNames: Set(urls.map { fileName(url: $0, owner: nil) }))
    }

    private func prune(keepingNames keep: Set<String>) {
        let keep = keep.union(loads.keys).union(fileReads.keys)
        // Invalidate before enqueueing deletion. Requests for removed names
        // must check disk behind the prune; retained/in-flight files stay fast.
        saved.formIntersection(keep)
        let directory = directory
        fileQueue.async {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
            for name in names where !keep.contains(name) {
                try? FileManager.default.removeItem(at: directory.appending(path: name))
            }
        }
    }

    func flushForTesting() async {
        await withCheckedContinuation { continuation in
            fileQueue.async { continuation.resume() }
        }
    }

    private func image(url: URL, owner: UUID?, credentialed: Bool, pixels: Int) async -> PlatformImage? {
        let key = Self.key(fileName(url: url, owner: owner), pixels)
        if let image = images.object(forKey: key) { return image }
        guard let file = await file(url: url, owner: owner, credentialed: credentialed) else { return nil }
        let image = await Task.detached(priority: .userInitiated) {
            ListenArtworkStore.decode(file, maxPixels: pixels)
        }.value
        if let image {
            images.setObject(image, forKey: key, cost: image.platformCGImage.map { $0.bytesPerRow * $0.height } ?? 0)
        }
        return image
    }

    private func savedFile(named name: String) -> URL? {
        let file = directory.appending(path: name)
        return FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) ? file : nil
    }

    private func isSameServer(_ item: ListenItem, _ url: URL) -> Bool {
        item.sourceID != nil || (server()?.isSameOrigin(url) ?? false)
    }

    private static func key(_ name: String, _ pixels: Int) -> NSString {
        "\(pixels) \(name)" as NSString
    }

    /// Saves `data` as an image at most `savedPixels` across: JPEG, or PNG
    /// when it has transparency.
    nonisolated static func save(_ data: Data, to destination: URL, in directory: URL) -> URL? {
        guard let image = downsample(CGImageSourceCreateWithData(data as CFData, nil), maxPixels: savedPixels) else {
            return nil
        }
        let opaque: [CGImageAlphaInfo] = [.none, .noneSkipFirst, .noneSkipLast]
        let type = opaque.contains(image.alphaInfo) ? UTType.jpeg : UTType.png
        let output = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(encoder, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(encoder) else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var folder = directory
            try? folder.setResourceValues(values)
            try (output as Data).write(to: destination, options: .atomic)
            return destination
        } catch {
            return nil
        }
    }

    /// Decodes `file` straight to at most `maxPixels` on the longer side.
    nonisolated static func decode(_ file: URL, maxPixels: Int) -> PlatformImage? {
        downsample(CGImageSourceCreateWithURL(file as CFURL, nil), maxPixels: maxPixels).map { PlatformImage.fromCGImage($0) }
    }

    private nonisolated static func downsample(_ source: CGImageSource?, maxPixels: Int) -> CGImage? {
        guard let source else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary)
    }
}
