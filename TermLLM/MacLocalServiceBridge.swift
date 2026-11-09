import Combine
import Foundation
import SwiftUI

/// Hands a verified local term-llm service to the client as This Mac, and
/// mirrors the Mac client window's visibility. Only the native Mac app has a
/// local service (TermLLMMac/MacLocalService.swift); on iPhone/iPad it is inert.
@MainActor
final class MacLocalServiceBridge: ObservableObject {
    static let shared = MacLocalServiceBridge()

    struct ChatRequest {
        let id = UUID()
        let baseURL: URL
        let token: String
        /// false: add or refresh This Mac in the background without opening Chat.
        var open = true
    }

    @Published private(set) var request: ChatRequest?
    @Published var error: String?
    /// The Mac client window is shown, not minimized or hidden.
    @Published private(set) var isMainWindowVisible = true
    /// The Mac client window's phase. iPhone/iPad use SwiftUI's scenePhase.
    @Published private(set) var windowPhase: ScenePhase = .active

    #if os(macOS)
    private var controller: MacLocalServiceController?
    #endif

    var isSupported: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// The unit-test host is this same app: same bundle ID, defaults and
    /// keychain. It must not add a menu-bar item or poll, update or connect
    /// the developer's real local service.
    static var isHostedTestRun: Bool {
        let environment = ProcessInfo.processInfo.environment
        return ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
            .contains { environment[$0]?.isEmpty == false }
    }

    func start() {
        #if os(macOS)
        guard controller == nil, !Self.isHostedTestRun else { return }
        let controller = MacLocalServiceController()
        // Runs only after the managed endpoint and its bearer credential pass
        // LocalSessionProbe. The credential stays in memory: never in URLs,
        // notifications, defaults or logs.
        controller.onConnection = { [weak self] baseURL, token, open in
            self?.receive(baseURL: baseURL, token: token, open: open)
        }
        self.controller = controller
        controller.startApplication()
        #endif
    }

    func receive(baseURL: URL, token: String, open: Bool) {
        guard let request = Self.request(baseURL: baseURL.absoluteString, token: token, open: open) else {
            // Background inclusion stays silent; only Open Chat reports.
            if open { error = "The local service returned an invalid connection." }
            return
        }
        if request.open {
            error = nil
        } else if self.request?.open == true {
            return // A pending Open Chat already adds This Mac.
        }
        self.request = request
    }

    /// Narrow, testable validation of a handoff. This checks syntax, not
    /// ownership: only the service manager supplies one, after its probe.
    static func request(baseURL raw: String, token: String, open: Bool) -> ChatRequest? {
        guard let url = HubConnectionStore.canonicalManagedLocalServiceURL(raw),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !token.contains("\r"), !token.contains("\n") else { return nil }
        return ChatRequest(baseURL: url, token: token, open: open)
    }

    static func effectiveScenePhase(_ phase: ScenePhase, isMainWindowVisible: Bool) -> ScenePhase {
        isMainWindowVisible ? phase : .background
    }

    /// Called by the Mac client window whenever it shows, hides or (de)activates.
    func clientWindowChanged(isVisible: Bool, phase: ScenePhase) {
        if isMainWindowVisible != isVisible { isMainWindowVisible = isVisible }
        if windowPhase != phase { windowPhase = phase }
    }

    func showLocalService() {
        #if os(macOS)
        start()
        controller?.showLocalService()
        #endif
    }

    func takeRequest(_ id: UUID) -> ChatRequest? {
        guard request?.id == id else { return nil }
        let pending = request
        request = nil
        return pending
    }
}
