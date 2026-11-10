import Foundation

/// Validate before constructing Sparkle: an unsigned development build must not
/// silently fall back to code-signature-only verification or contact a feed.
struct AppUpdatePolicy {
    static let productionFeed = "https://term-llm.com/mac/appcast.xml"

    static var allowsLocalTestFeed: Bool {
        #if DEBUG || SPARKLE_LOCAL_FEED_TEST
        true
        #else
        false
        #endif
    }

    static func disabledReason(info: [String: Any], suppressed: Bool,
                               allowLocalTestFeed: Bool = allowsLocalTestFeed) -> String? {
        if suppressed { return "Update checks are disabled in fixtures and hosted tests." }
        guard let key = info["SUPublicEDKey"] as? String,
              let decoded = Data(base64Encoded: key), decoded.count == 32,
              decoded.base64EncodedString() == key, decoded.contains(where: { $0 != 0 }) else {
            return "App updates disabled: inject a valid 32-byte base64 SPARKLE_PUBLIC_ED_KEY in the build configuration."
        }
        guard info["SUVerifyUpdateBeforeExtraction"] as? Bool == true else {
            return "App updates disabled: SUVerifyUpdateBeforeExtraction must be true (EdDSA required)."
        }
        guard info["SURequireSignedFeed"] as? Bool == true,
              let expiration = info["SUSignedFeedFailureExpirationInterval"] as? NSNumber,
              expiration.doubleValue == 0 else {
            return "App updates disabled: signed appcasts are required with no signature-failure expiration bypass."
        }
        guard let automatic = info["SUAllowsAutomaticUpdates"] as? Bool, !automatic else {
            return "App updates disabled: installation must require manual confirmation."
        }
        guard let feed = info["SUFeedURL"] as? String else {
            return "App updates disabled: missing SPARKLE_FEED_URL."
        }
        if feed == productionFeed { return nil }
        // Release builds only accept the production feed, unless compiled with
        // the explicit SPARKLE_LOCAL_FEED_TEST condition for ad-hoc VM demos.
        // Neither defaults nor runtime environment variables can enable this.
        guard allowLocalTestFeed, let url = URLComponents(string: feed),
              url.scheme == "http", url.host == "127.0.0.1",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !url.path.isEmpty else {
            return "App updates disabled: nonproduction feed requires a local-test build and an HTTP 127.0.0.1 URL."
        }
        return nil
    }
}


/// Bounded, cancellation-aware asynchronous drain. A shutdown acknowledgment is
/// not readiness: callers predicate on actual work completion/process exit.
@MainActor
enum AppUpdateDrain {
    static func waitUntil(timeout: Duration, isReady: () -> Bool) async throws {
        try Task.checkCancellation()
        let deadline = ContinuousClock.now + timeout
        while !isReady() {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw NSError(domain: "AppUpdateDrain", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for app-owned work to finish."])
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
