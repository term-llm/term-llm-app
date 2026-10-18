import Foundation
@testable import TermLLM

/// Test doubles at the AVFoundation/WebKit boundary.

@MainActor
final class FakeListenEngine: ListenEngine {
    var onEvent: (@MainActor (ListenEngineEvent) -> Void)?
    var currentTime: TimeInterval = 0
    var duration: TimeInterval?
    var loadError: Error?
    /// Durations reported per URL once loaded.
    var durations: [URL: TimeInterval] = [:]
    private(set) var loads: [(source: ListenSource, startAt: TimeInterval)] = []
    private(set) var playing = false
    private(set) var rates: [Float] = []
    private(set) var stops = 0

    func load(_ source: ListenSource, startAt: TimeInterval) async throws {
        loads.append((source, startAt))
        if let loadError { throw loadError }
        currentTime = startAt
        duration = durations[source.url]
    }

    func play(rate: Float) throws {
        playing = true
        rates.append(rate)
    }

    func pause() { playing = false }

    func seek(to seconds: TimeInterval) async { currentTime = seconds }

    func setRate(_ rate: Float) { rates.append(rate) }

    func stop() {
        playing = false
        stops += 1
    }

    func send(_ event: ListenEngineEvent) { onEvent?(event) }
}

@MainActor
final class FakeCookieJar: ListenCookieJar {
    var cookies: [HTTPCookie] = []
    private(set) var requested: [URL] = []

    func cookies(for url: URL) async -> [HTTPCookie] {
        requested.append(url)
        return cookies
    }
}

let testServer = ListenServer(base: URL(string: "https://hub.example/ui/")!)

func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "listen-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func draft(_ name: String, title: String? = nil, host: String = "pod.example") -> ListenDraft {
    ListenDraft(url: URL(string: "https://\(host)/\(name).mp3")!, title: title)
}

@MainActor
func makeListen(engine: FakeListenEngine? = nil, cookies: FakeCookieJar? = nil,
                directory: URL = temporaryDirectory(),
                fetch: ListenDownloader.Fetch? = nil) -> Listen {
    let engine = engine ?? FakeListenEngine()
    let cookies = cookies ?? FakeCookieJar()
    return Listen(store: ListenStore(fileURL: directory.appending(path: "library.json")), engine: engine, cookies: cookies,
           server: { testServer }, downloadDirectory: directory.appending(path: "Downloads"),
           fetch: fetch ?? { _ in throw URLError(.notConnectedToInternet) }, defaults: isolatedDefaults())
}

/// Waits for main-actor tasks spawned by the code under test.
@MainActor
func settle() async {
    for _ in 0..<20 { await Task.yield() }
}
