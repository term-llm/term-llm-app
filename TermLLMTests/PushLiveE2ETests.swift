import UserNotifications
import WebKit
import XCTest
@testable import TermLLM

/// Opt-in end-to-end check of native push against a real term-llm server and
/// push relay:
///
/// 1. The real web UI enrolls itself through `window.__termLLMNativePush`
///    (no clicks), registering the relay endpoint with the server.
/// 2. Outside the test, `term-llm notify web "<body>"` sends Web Push to the
///    relay, which forwards an APNs request to a capturing fake APNs.
/// 3. The test fetches that APNs payload and runs the Notification Service
///    Extension's class on it, decrypting with the keys in the real keychain.
///
/// Env (TEST_RUNNER_ prefix when run through xcodebuild):
/// TERMLLM_PUSH_E2E_URL (web UI, e.g. http://127.0.0.1:18090/ui/),
/// TERMLLM_PUSH_E2E_RELAY (e.g. http://localhost:18080),
/// TERMLLM_PUSH_E2E_APNS (fake APNs with GET /last) and TERMLLM_PUSH_E2E_BODY.
@MainActor
final class PushLiveE2ETests: XCTestCase {
    func testWebUIEnrollsAndExtensionDecryptsRelayedPush() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["TERMLLM_PUSH_E2E_URL"], let server = URL(string: raw),
              let relay = env["TERMLLM_PUSH_E2E_RELAY"], let apns = env["TERMLLM_PUSH_E2E_APNS"].flatMap(URL.init(string:)),
              let expectedBody = env["TERMLLM_PUSH_E2E_BODY"] else {
            throw XCTSkip("Set TEST_RUNNER_TERMLLM_PUSH_E2E_URL, _RELAY, _APNS and _BODY to run")
        }
        UserDefaults.standard.set(relay, forKey: PushCenter.relayOverrideKey)
        // Provisional authorization never prompts, so this runs unattended.
        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.provisional, .alert, .sound])
        let center = PushCenter.shared
        await center.setEnabled(true)
        XCTAssertTrue(center.enabled)
        // A simulator may not get a real APNs token; the fake APNs does not care.
        center.didRegister(deviceToken: Data((0..<32).map { UInt8($0) }))

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let bridge = NativePushBridge(serverURL: server, center: center)
        bridge.install(into: configuration.userContentController)
        defer { bridge.uninstall() }
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        let window = UIWindow(frame: webView.frame)
        let controller = UIViewController()
        controller.view = webView
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        webView.load(URLRequest(url: server))

        // The page enrolls itself: no clicks (permission is already granted).
        let origin = NativeLogin.origin(for: server)
        let scope = server.path.hasSuffix("/") ? String(server.path.dropLast()) : server.path
        var enrolled: NativePushSubscription?
        for _ in 0..<120 where enrolled == nil {
            try await Task.sleep(for: .milliseconds(500))
            enrolled = center.subscription(origin: origin, scope: scope)
        }
        let subscription = try XCTUnwrap(enrolled, "the web UI did not enroll through the native bridge")
        XCTAssertTrue(subscription.endpoint.hasPrefix(relay + "/v1/push/"))
        print("PUSH_E2E_ENROLLED \(subscription.endpoint)")

        // Wait for the relay's APNs request, then decrypt it as the extension would.
        for _ in 0..<240 {
            if let (data, response) = try? await URLSession.shared.data(from: apns.appending(path: "last")),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let content = runExtension(on: payload), content.body == expectedBody {
                XCTAssertEqual(content.title, "term-llm")
                XCTAssertNil(content.userInfo["webpush"], "extension replaced the encrypted envelope")
                XCTAssertEqual(content.userInfo[PushMessage.originKey] as? String, origin, "source tag routed to this server")
                print("PUSH_E2E_DECRYPTED \(content.title): \(content.body)")
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTFail("no relayed push decrypted to \(expectedBody)")
    }

    private func runExtension(on payload: [String: Any]) -> UNNotificationContent? {
        let content = UNMutableNotificationContent()
        let aps = payload["aps"] as? [String: Any]
        let alert = aps?["alert"] as? [String: Any]
        content.title = alert?["title"] as? String ?? ""
        content.body = alert?["body"] as? String ?? ""
        content.userInfo = payload
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        return try? PushMessage.content(for: request) // exactly what the extension delivers
    }
}
