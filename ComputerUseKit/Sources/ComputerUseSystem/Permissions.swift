import AppKit
import ApplicationServices
import ComputerUseCore
import Foundation

/// Grants belong to this LSUIElement helper, not a terminal or the parent app.
/// Request functions must execute here, so this helper is listed in System Settings.
public final class Permissions {
    public static let settingsURL = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?"
    public static let settingsApp = "com.apple.systempreferences"
    public static let poll = 0.25
    public static let giveUp = 10.0 // Stop this long before the client; say "call again".
    public static let toolLook = 1.0
    public enum Kind: String, CaseIterable {
        case accessibility, screenRecording = "screen_recording", postEvents = "post_events", inputMonitoring = "input_monitoring"
        public var pane: String {
            switch self {
            case .accessibility, .postEvents: return "Privacy_Accessibility"
            case .screenRecording: return "Privacy_ScreenCapture"
            case .inputMonitoring: return "Privacy_ListenEvent"
            }
        }
        public var why: String {
            switch self {
            case .accessibility: return "Allows \(product) to read and operate app interfaces"
            case .screenRecording: return "\(product) reads screenshots to find where to click"
            case .postEvents: return "Allows \(product) to send clicks and keys to one app"
            case .inputMonitoring: return "Lets \(product) notice when you use an app yourself, and step back"
            }
        }
    }
    public static let required: [Kind] = [.accessibility, .screenRecording]
    public struct Calls {
        public var granted: (Kind) -> Bool = { kind in
            switch kind {
            case .accessibility: return AXIsProcessTrusted()
            case .screenRecording: return CGPreflightScreenCaptureAccess()
            case .postEvents: return CGPreflightPostEventAccess()
            case .inputMonitoring: return CGPreflightListenEventAccess()
            }
        }
        public var request: (Kind) -> Void = { kind in
            switch kind {
            case .accessibility: _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            case .screenRecording: _ = CGRequestScreenCaptureAccess()
            case .postEvents: _ = CGRequestPostEventAccess()
            case .inputMonitoring: _ = CGRequestListenEventAccess()
            }
        }
        public var open: (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
        public var settingsOpen: () -> Bool = { !NSRunningApplication.runningApplications(withBundleIdentifier: Permissions.settingsApp).isEmpty }
        public var canCapture: () -> Bool = { Screenshot().canCapture() }
        public var time: () -> TimeInterval = { Date().timeIntervalSince1970 }
        public var monotonic: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        public var sleep: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)
        public init() {}
    }
    private let calls: Calls
    private let lock = NSRecursiveLock()
    private var seenGranted: Set<Kind> = [] // A grant does not go away while the helper lives.
    private var toolSaid: (TimeInterval, Bool) = (-Permissions.toolLook, false)
    public init(calls: Calls = Calls()) { self.calls = calls }
    public static func url(_ kind: Kind) -> URL { URL(string: settingsURL + kind.pane)! }
    public static func names(_ kinds: [Kind]) -> String { kinds.map { $0.rawValue.replacingOccurrences(of: "_", with: " ").capitalized }.joined(separator: " and ") }
    public static func responsibleApp() -> String { product }
    public func toolCanCapture() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if calls.monotonic() - toolSaid.0 >= Self.toolLook { toolSaid = (calls.monotonic(), calls.canCapture()) }
        return toolSaid.1
    }
    private func granted(_ kind: Kind) -> Bool {
        // CGPreflightScreenCaptureAccess keeps the answer from process start. The
        // child tool asks afresh, so a later grant works at once without a restart.
        calls.granted(kind) || (kind == .screenRecording && toolCanCapture())
    }
    public func status() -> [String: Bool] { Dictionary(uniqueKeysWithValues: Kind.allCases.map { ($0.rawValue, granted($0)) }) }
    public func request(_ kind: Kind) { MainThread.callOnMain { self.calls.request(kind) } }
    public func openSettings(_ kind: Kind) {
        MainThread.callOnMain { self.calls.request(kind); self.calls.open(Self.url(kind)) }
    }
    private func missing() -> [Kind] {
        lock.lock(); defer { lock.unlock() }
        for kind in Self.required where !seenGranted.contains(kind) && granted(kind) { seenGranted.insert(kind) }
        return Self.required.filter { !seenGranted.contains($0) }
    }
    /// deadline is wall-clock seconds since 1970, matching the client's deadline.
    /// Return once grants exist. Closing Settings after seeing it means refused;
    /// a pane that never launched is not a refusal. Abandoned clients stop waiting.
    public func gate(deadline: TimeInterval, abandoned: () -> Bool = { false }) throws {
        var shown: Kind?, settingsSeen = false
        while true {
            let missing = missing()
            guard let first = missing.first else { return }
            if first != shown { shown = first; settingsSeen = false; openSettings(first) }
            else if calls.settingsOpen() { settingsSeen = true }
            else if settingsSeen { throw Errors.make("permissions_not_granted", ["grants": Self.names(missing), "app": product]) }
            if calls.time() >= deadline - Self.giveUp { throw Errors.make("permissions_pending", ["app": product, "grants": Self.names(missing)]) }
            if abandoned() { throw Errors.make("request_timed_out") }
            calls.sleep(Self.poll)
        }
    }
    /// Observable diagnostics, with no prompt or Settings launch. The grant owner
    /// is always this helper; there is deliberately no terminal/doctor ancestry.
    public func diagnostics() -> [String: Any] {
        let granted = status()
        var missing: [String: [String: String]] = [:]
        for kind in Kind.allCases where granted[kind.rawValue] != true { missing[kind.rawValue] = ["why": kind.why, "settings": Self.url(kind).absoluteString] }
        return ["ready": Self.required.allSatisfy { granted[$0.rawValue] == true }, "app": product, "granted": granted, "missing": missing]
    }
}
