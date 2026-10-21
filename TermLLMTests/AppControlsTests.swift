import SwiftUI
import WebKit
import XCTest
@testable import TermLLM

@MainActor
final class AppControlsTests: XCTestCase {
    private final class State {
        var expanded = false
        var actions: [AppControlAction] = []
        let defaults: UserDefaults

        init(defaults: UserDefaults = isolatedDefaults()) { self.defaults = defaults }
    }

    private func bar(_ state: State, canGoBack: Bool = false) -> AppControlsBar {
        AppControlsBar(
            isExpanded: Binding(get: { state.expanded }, set: { state.expanded = $0 }),
            hintAcknowledged: Binding(
                get: { state.defaults.bool(forKey: AppControlsBar.hintAcknowledgedKey) },
                set: { state.defaults.set($0, forKey: AppControlsBar.hintAcknowledgedKey) }),
            canGoBack: canGoBack, onAction: { state.actions.append($0) })
    }

    func testOpeningControlsAcknowledgesHintAndDoesNotNavigate() {
        let state = State()
        XCTAssertFalse(state.defaults.bool(forKey: AppControlsBar.hintAcknowledgedKey))
        XCTAssertTrue(bar(state).isVisible, "Only the first-use coachmark is initially visible")
        bar(state).reveal()
        XCTAssertTrue(state.expanded)
        XCTAssertTrue(state.defaults.bool(forKey: AppControlsBar.hintAcknowledgedKey))
        XCTAssertTrue(state.actions.isEmpty)
        // Learning the menu survives view recreation / another server.
        let reopened = State(defaults: state.defaults)
        XCTAssertTrue(reopened.defaults.bool(forKey: AppControlsBar.hintAcknowledgedKey))
        XCTAssertFalse(reopened.expanded)
    }

    func testDismissingHintDoesNotOpenControlsOrSettings() {
        let state = State()
        bar(state).dismissHint()
        XCTAssertTrue(state.defaults.bool(forKey: AppControlsBar.hintAcknowledgedKey))
        XCTAssertFalse(state.expanded)
        XCTAssertTrue(state.actions.isEmpty)
        XCTAssertFalse(bar(state).isVisible, "Dismissing the teacher leaves no permanent chrome")
        bar(state).reveal()
        XCTAssertTrue(state.expanded, "The pull/accessibility reveal remains usable after dismissing the hint")
    }

    func testEachControlClosesTheFloatingBarAndLeavesNoChrome() {
        for action in AppControlAction.allCases {
            let state = State()
            bar(state).reveal()
            bar(state, canGoBack: true).activate(action)
            XCTAssertEqual(state.actions, [action])
            XCTAssertFalse(state.expanded)
            XCTAssertFalse(bar(state).isVisible)
            XCTAssertTrue(state.defaults.bool(forKey: AppControlsBar.hintAcknowledgedKey))
        }
    }

    func testOpeningDoesNotResetAnAlreadyAcknowledgedHint() {
        let state = State()
        bar(state).dismissHint()
        bar(state).reveal()
        state.expanded = false
        bar(state).reveal()
        XCTAssertTrue(state.expanded)
        XCTAssertTrue(state.defaults.bool(forKey: AppControlsBar.hintAcknowledgedKey))
    }

    func testControlsAndTeacherLayouts() async throws {
        let state = State()
        try await render(bar(state), named: "app-controls-first-use")
        bar(state).dismissHint()
        try await render(bar(state), named: "app-controls-collapsed")
        bar(state).reveal()
        try await render(bar(state, canGoBack: true), named: "app-controls-expanded")
        try await render(bar(state).frame(width: 320), named: "app-controls-narrow-expanded")
        let fresh = State()
        try await render(bar(fresh).frame(width: 320).dynamicTypeSize(.accessibility2),
                         named: "app-controls-large-text-hint")
    }

    /// Opt-in against the public demo or a locally served build. The native
    /// overlay must never reserve page space, reload WebKit, or keep chrome
    /// visible once the first-use hint has been acknowledged.
    func testLiveBrowserViewportIsUnchangedByHintAndControls() async throws {
        guard let raw = ProcessInfo.processInfo.environment["TERMLLM_DEMO_E2E_URL"],
              let server = ServerAddress.parse(raw) else {
            throw XCTSkip("Set TERMLLM_DEMO_E2E_URL to exercise the real browser overlay")
        }
        let defaults = UserDefaults.standard
        let oldServer = defaults.object(forKey: "serverURL")
        let oldHint = defaults.object(forKey: AppControlsBar.hintAcknowledgedKey)
        defaults.set(server.absoluteString, forKey: "serverURL")
        defaults.set(true, forKey: AppControlsBar.hintAcknowledgedKey)
        defer {
            defaults.set(oldServer, forKey: "serverURL")
            defaults.set(oldHint, forKey: AppControlsBar.hintAcknowledgedKey)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: ContentView())
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func findWebView(_ view: UIView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.compactMap(findWebView).first
        }
        try await Task.sleep(for: .milliseconds(300))
        let web = try XCTUnwrap(findWebView(window))
        var ready = false
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("!!document.querySelector('#promptInput')")) as? Bool == true {
                ready = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(ready, "The demo composer should load")
        let viewport = web.convert(web.bounds, to: window)
        _ = try await web.evaluateJavaScript("window.__appControlsViewportTest = 'unchanged'")
        func capture(_ name: String) {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        capture("live-demo-controls-hidden")
        defaults.set(false, forKey: AppControlsBar.hintAcknowledgedKey)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(web.convert(web.bounds, to: window), viewport, "The coachmark must overlay, not resize the page")
        capture("live-demo-floating-coachmark")
        let coordinator = try XCTUnwrap(web.navigationDelegate as? BrowserView.Coordinator)
        coordinator.parent.onRevealControls()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(web.convert(web.bounds, to: window), viewport, "Revealing controls must not move the page")
        XCTAssertTrue(defaults.bool(forKey: AppControlsBar.hintAcknowledgedKey))
        let sentinel = try await web.evaluateJavaScript("window.__appControlsViewportTest") as? String
        XCTAssertEqual(sentinel, "unchanged", "Revealing controls must not reload the page")
        capture("live-demo-floating-controls")
    }

    private func render<Content: View>(_ controls: Content, named name: String) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView:
            Color.gray.opacity(0.08)
                .overlay(Text("Conversation").foregroundStyle(.secondary))
                .overlay(alignment: .top) {
                    controls.padding(.horizontal, 12).padding(.top, 10)
                }
                .tint(.cyan))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let pixels = try XCTUnwrap(cgImage.dataProvider?.data as Data?)
        let first = pixels.prefix(4)
        XCTAssertTrue(stride(from: 0, to: pixels.count - 4, by: 4 * 97).contains {
            pixels[$0..<$0 + 4] != first
        }, "\(name) should not render a blank screen")
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
