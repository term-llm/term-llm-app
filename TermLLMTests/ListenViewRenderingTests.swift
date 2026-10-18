import SwiftUI
import XCTest
@testable import TermLLM

/// Renders the Listen screens with sample data in a real window, like
/// `MusicViewRenderingTests`; screenshots are attached to the test result.
@MainActor
final class ListenViewRenderingTests: XCTestCase {
    private func sampleListen() async throws -> Listen {
        let engine = FakeListenEngine()
        let listen = makeListen(engine: engine)
        let items = try await listen.add([
            ListenDraft(url: URL(string: "https://hub.example/media/brief.mp3")!, title: "Morning briefing: Sunday 18 October",
                        artist: "term-llm · af_sky", kind: .generated, duration: 412),
            ListenDraft(url: URL(string: "https://feeds.example/ep212.mp3")!, title: "Episode 212: The long tail of caches",
                        artist: "Systems Weekly", kind: .episode, duration: 3_720),
            ListenDraft(url: URL(string: "https://feeds.example/ep88.mp3")!, title: "How sound effects are made",
                        artist: "Twenty Thousand Hertz", kind: .episode, duration: 1_980),
        ], placement: .now, download: .never)
        engine.duration = 412
        engine.currentTime = 95
        engine.send(.tick)
        listen.store.update(items[2].id) { $0.status = .inProgress; $0.position = 600 }
        let old = listen.store.add([ListenDraft(url: URL(string: "https://feeds.example/ep1.mp3")!, title: "Pilot",
                                                artist: "Systems Weekly", kind: .episode, duration: 1_500)], placement: .end)
        try listen.store.setStatus([old[0].id], .played)
        return listen
    }

    private func render<Content: View>(_ view: Content, named name: String) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(800))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        window.isHidden = true
    }

    func testMiniPlayerUnderPage() async throws {
        let listen = try await sampleListen()
        try await render(VStack(spacing: 0) {
            Color.cyan.opacity(0.15).overlay(Text("web page"))
            MiniPlayerBar(listen: listen) {}
        }, named: "listen-mini-player")
    }

    func testPlayerSheet() async throws {
        let listen = try await sampleListen()
        listen.player.sleepAtEndOfItem()
        try await render(ListenPlayerView(listen: listen), named: "listen-player")
    }

    func testLibrary() async throws {
        let listen = try await sampleListen()
        try await render(ListenView(listen: listen), named: "listen-library")
        try await render(ListenView(listen: makeListen()), named: "listen-empty")
    }
}
