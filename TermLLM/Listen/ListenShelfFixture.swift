#if DEBUG && targetEnvironment(simulator)
import Foundation
import UIKit

/// Local data for the real ContentView tab shell, not an alternate player UI.
/// Requires the isolated, visibly labelled phone fixture as well as this opt-in.
@MainActor
enum ListenShelfFixture {
    static func makeIfEnabled() -> Listen? {
        guard PhoneHubFixture.isEnabled,
              ProcessInfo.processInfo.environment["TERMLLM_LISTEN_SHELF_FIXTURE"] == "1" else { return nil }
        do {
            let directory = FileManager.default.temporaryDirectory.appending(path: "listen-shelf-fixture", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Reset only this fixture's files/defaults; never the user's library.
            for name in ["library.json", "library-positions.json"] {
                let url = directory.appending(path: name)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            let defaults = UserDefaults(suiteName: "com.termllm.app.listen-shelf-fixture")!
            defaults.removePersistentDomain(forName: "com.termllm.app.listen-shelf-fixture")
            let audio = directory.appending(path: "episode.wav")
            try writeSilentEpisode(to: audio)
            let artwork = ListenArtworkStore(directory: directory.appending(path: "Artwork"), cookies: nil, server: { nil })
            let cover = try saveCover(in: artwork)
            let listen = Listen(store: ListenStore(fileURL: directory.appending(path: "library.json")),
                                engine: AVListenEngine(), cookies: WebKitCookieJar(), server: { nil },
                                nowPlaying: SystemNowPlaying(artwork: artwork), artwork: artwork,
                                downloadDirectory: directory, defaults: defaults)
            let item = listen.store.add([
                ListenDraft(url: audio,
                            title: "Episode 212: The long tail of caches and distributed systems",
                            artist: "Systems Weekly · Infrastructure conversations", artworkURL: cover,
                            kind: .episode, duration: 3_720),
            ], placement: .end)[0]
            listen.store.setPosition(95, for: item.id)
            Task {
                do { try await listen.player.play(item.id) }
                catch { assertionFailure("Local shelf fixture could not start: \(error)") }
            }
            return listen
        } catch {
            preconditionFailure("Could not prepare local shelf fixture: \(error)")
        }
    }

    /// Original editorial-style network/server illustration, generated offline.
    /// Keep the solid center colors in sync with the compact screenshot test.
    private static func saveCover(in store: ListenArtworkStore) throws -> URL {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let data = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160), format: format).pngData { context in
            func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor {
                UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1)
            }
            let navy = color(14, 25, 46)
            let amber = color(232, 153, 45)
            let gold = color(250, 211, 112)
            navy.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
            gold.setFill()
            UIBezierPath(ovalIn: CGRect(x: 94, y: 14, width: 28, height: 28)).fill()
            context.fill(CGRect(x: 52, y: 77, width: 56, height: 6))
            for (x, fill) in [(32, amber), (88, gold)] {
                fill.setFill()
                UIBezierPath(roundedRect: CGRect(x: x, y: 48, width: 40, height: 68), cornerRadius: 5).fill()
                navy.setFill()
                for y in [56, 102] {
                    context.fill(CGRect(x: x + 8, y: y, width: 24, height: 5))
                }
            }
            amber.setFill()
            context.fill(CGRect(x: 32, y: 132, width: 62, height: 4))
            gold.setFill()
            context.fill(CGRect(x: 100, y: 132, width: 28, height: 4))
        }
        // A local identity, not a network URL. Seed the actual store's hashed
        // file so ListenArtwork and Now Playing use their normal decode path.
        let cover = store.directory.appending(path: "systems-weekly-cover.png")
        let destination = store.directory.appending(path: store.fileName(url: cover, owner: nil))
        guard ListenArtworkStore.save(data, to: destination, in: store.directory) != nil else {
            throw ListenError.storageUnavailable("Could not save local shelf cover")
        }
        return cover
    }

    /// A valid 62-minute mono PCM WAV. Sparse zero-filled samples keep setup
    /// fast and silent while AVPlayer supplies real duration/playhead updates.
    private static func writeSilentEpisode(to url: URL) throws {
        let sampleRate: UInt32 = 8_000
        let byteCount: UInt32 = 3_720 * sampleRate * 2
        var header = Data()
        func text(_ value: String) { header.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { header.append(contentsOf: $0) }
        }
        text("RIFF"); number(byteCount + 36); text("WAVEfmt "); number(UInt32(16))
        number(UInt16(1)); number(UInt16(1)); number(sampleRate); number(sampleRate * 2)
        number(UInt16(2)); number(UInt16(16)); text("data"); number(byteCount)
        try header.write(to: url)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.truncate(atOffset: UInt64(header.count) + UInt64(byteCount))
    }
}
#endif
