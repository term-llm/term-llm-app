import AppKit
import ApplicationServices
import ComputerUseCore
import Darwin
import Foundation
import os

/// Grants belong to this LSUIElement helper, not a terminal or the parent app.
/// Request functions must execute here, so this helper is listed in System Settings.
public final class Permissions: Sendable {
    public static let settingsURL = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?"
    public static let settingsApp = "com.apple.systempreferences"
    public static let poll = 0.25
    public static let giveUp = 10.0 // Stop this long before the client; say "call again".
    public static let toolLook = 1.0
    public enum Kind: String, CaseIterable, Sendable {
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
    /// Copied at initialization. Worker preflights/capture checks stay on the
    /// caller; only request/open use the synchronous main-thread handoff. Hooks
    /// may run concurrently and reenter Permissions; none run under a state lock.
    public struct Calls: Sendable {
        public var granted: @Sendable (Kind) -> Bool = { kind in
            switch kind {
            case .accessibility: return AXIsProcessTrusted()
            case .screenRecording: return CGPreflightScreenCaptureAccess()
            case .postEvents: return CGPreflightPostEventAccess()
            case .inputMonitoring: return CGPreflightListenEventAccess()
            }
        }
        public var request: @Sendable (Kind) -> Void = { kind in
            switch kind {
            // The key is kAXTrustedCheckOptionPrompt's value: Swift 6 imports that C global as shared mutable state.
            case .accessibility: _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            case .screenRecording: _ = CGRequestScreenCaptureAccess()
            case .postEvents: _ = CGRequestPostEventAccess()
            case .inputMonitoring: _ = CGRequestListenEventAccess()
            }
        }
        public var open: @Sendable (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
        public var settingsOpen: @Sendable () -> Bool = { !NSRunningApplication.runningApplications(withBundleIdentifier: Permissions.settingsApp).isEmpty }
        public var canCapture: @Sendable () -> Bool = { Screenshot().canCapture() }
        public var time: @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
        public var monotonic: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        public var sleep: @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
        /// Must run work synchronously, just like MainThread.callOnMain. The seam
        /// exists to test the handoff without starting an AppKit run loop.
        public var callOnMain: @Sendable (@Sendable () -> Void) -> Void = { MainThread.callOnMain($0) }
        public init() {}
    }
    private let calls: Calls
    /// A synchronous probe belongs to its calling thread until publication. The
    /// completion signal has no callbacks and is never waited on under state's
    /// lock. Direct callback reentry must not wait on its own unfinished probe.
    private final class Probe: Sendable {
        let owner: mach_port_t
        private let done = DispatchGroup()
        init(owner: mach_port_t) { self.owner = owner; done.enter() }
        var isFinished: Bool { done.wait(timeout: .now()) == .success }
        var isCurrentThread: Bool { owner == pthread_mach_thread_np(pthread_self()) }
        func finish() { done.leave() }
        func wait() { done.wait() }
    }
    private enum Grant: Sendable {
        case allowed, denied, pending(Probe)
    }
    private struct Missing: Sendable {
        var kinds: [Kind]
        var pending: [Probe]
    }
    private struct State: Sendable {
        var seenGranted: Set<Kind> = [] // Gate remembers grants for the helper lifetime; status stays live.
        var checking: [Kind: Probe] = [:]
        var toolSaid: (time: TimeInterval, granted: Bool) = (-Permissions.toolLook, false)
        var toolChecking: Probe?
        var awaitingRelaunch: Set<Kind> = []
        var pendingRelaunch: [Kind: UInt64] = [:]
        var settingsSeenSinceAllow = false
        var relaunchChecking = false
        var relaunchRevision: UInt64 = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    public init(calls: Calls = Calls()) { self.calls = calls }
    public static func url(_ kind: Kind) -> URL { URL(string: settingsURL + kind.pane)! }
    public static func names(_ kinds: [Kind]) -> String { kinds.map { $0.rawValue.replacingOccurrences(of: "_", with: " ").capitalized }.joined(separator: " and ") }
    public static func responsibleApp() -> String { product }
    /// One caller refreshes the child-tool cache; other callers wait for that
    /// publication, as before. A direct reentrant callback cannot wait on itself
    /// and gets the last published answer instead. Gates use explicit pending
    /// results internally so this fallback is never mistaken for a denial.
    /// The cooldown starts at the claimant's monotonic sample, including failure.
    public func toolCanCapture() -> Bool {
        switch captureGrant() {
        case .allowed: return true
        case .denied: return false
        case .pending(let probe):
            if !probe.isCurrentThread { probe.wait() }
            return state.withLock { $0.toolSaid.granted }
        }
    }
    private func captureGrant() -> Grant {
        let owner = pthread_mach_thread_np(pthread_self())
        let claim = state.withLock { state -> (probe: Probe, claimed: Bool, cached: Bool) in
            if let probe = state.toolChecking { return (probe, false, state.toolSaid.granted) }
            let probe = Probe(owner: owner)
            state.toolChecking = probe
            return (probe, true, state.toolSaid.granted)
        }
        guard claim.claimed else { return .pending(claim.probe) }
        // Claim before even the clock callback: it too can reenter this method.
        let time = calls.monotonic()
        let due = state.withLock { time - $0.toolSaid.time >= Self.toolLook }
        let answer = due ? calls.canCapture() : claim.cached
        state.withLock {
            if due { $0.toolSaid = (time, answer) }
            $0.toolChecking = nil
        }
        claim.probe.finish()
        return answer ? .allowed : .denied
    }
    private func gateGrant(_ kind: Kind) -> Grant {
        if calls.granted(kind) { return .allowed }
        return kind == .screenRecording ? captureGrant() : .denied
    }
    private func granted(_ kind: Kind) -> Bool {
        // CGPreflightScreenCaptureAccess keeps the answer from process start. The
        // child tool asks afresh, so a later grant works at once without a restart.
        calls.granted(kind) || (kind == .screenRecording && toolCanCapture())
    }
    public func status() -> [String: Bool] { Dictionary(uniqueKeysWithValues: Kind.allCases.map { ($0.rawValue, granted($0)) }) }
    public func request(_ kind: Kind) { calls.callOnMain { self.calls.request(kind) } }
    public func openSettings(_ kind: Kind) {
        if Self.readAtLaunch.contains(kind) {
            // Reserve before the injected preflight. A reentrant/concurrent newer
            // Allow intent or consumed relaunch invalidates this older publication.
            let revision = state.withLock {
                $0.relaunchRevision += 1
                $0.pendingRelaunch[kind] = $0.relaunchRevision
                return $0.relaunchRevision
            }
            let allowed = granted(kind)
            state.withLock {
                guard $0.pendingRelaunch[kind] == revision else { return }
                $0.pendingRelaunch.removeValue(forKey: kind)
                if !allowed {
                    $0.awaitingRelaunch.insert(kind)
                    $0.settingsSeenSinceAllow = false
                }
                $0.relaunchRevision += 1
            }
        }
        calls.callOnMain { self.calls.request(kind); self.calls.open(Self.url(kind)) }
    }
    /// macOS answers these preflights from what the process had at launch (System
    /// Settings says Input Monitoring needs "Quit & Reopen"), and the event tap is
    /// only made at startup. A grant given in Settings shows only to a new helper.
    public static let readAtLaunch: Set<Kind> = [.inputMonitoring, .postEvents]
    /// True once, after Allow… for a launch-read grant, when the person has been
    /// to System Settings and closed it again: the helper should exit so its owner
    /// starts a new one that sees the grant. Asked from the maintenance timer.
    public func wantsRelaunch() -> Bool {
        let revision = state.withLock { state -> UInt64? in
            guard !state.awaitingRelaunch.isEmpty, !state.relaunchChecking else { return nil }
            state.relaunchChecking = true
            return state.relaunchRevision
        }
        guard let revision else { return false }
        // One poll at a time, without waiting: a delayed closed sample cannot
        // consume the Settings-seen bit from a newer overlapping open sample.
        let open = calls.settingsOpen()
        return state.withLock {
            $0.relaunchChecking = false
            guard $0.relaunchRevision == revision else { return false }
            if open { $0.settingsSeenSinceAllow = true; return false }
            guard $0.settingsSeenSinceAllow else { return false }
            $0.awaitingRelaunch.removeAll()
            $0.pendingRelaunch.removeAll()
            $0.relaunchRevision += 1
            return true
        }
    }
    // A not-yet-published grant is pending, not denied. Keep the actual probe
    // token even if it finishes during this snapshot: gate will retry rather
    // than infer a denial from an operation it did not observe completing.
    private func missing() -> Missing {
        var pending: [Kind: Probe] = [:]
        let owner = pthread_mach_thread_np(pthread_self())
        for kind in Self.required {
            let claim = state.withLock { state -> (probe: Probe, claimed: Bool)? in
                guard !state.seenGranted.contains(kind) else { return nil }
                if let probe = state.checking[kind] { return (probe, false) }
                let probe = Probe(owner: owner)
                state.checking[kind] = probe
                return (probe, true)
            }
            guard let claim else { continue }
            guard claim.claimed else { pending[kind] = claim.probe; continue }
            let result = gateGrant(kind)
            state.withLock {
                if case .allowed = result { $0.seenGranted.insert(kind) }
                $0.checking.removeValue(forKey: kind)
            }
            claim.probe.finish()
            if case .pending(let probe) = result { pending[kind] = probe }
        }
        return state.withLock { [pending] state in
            let kinds = Self.required.filter { !state.seenGranted.contains($0) }
            return Missing(kinds: kinds, pending: kinds.compactMap { state.checking[$0] ?? pending[$0] })
        }
    }
    /// deadline is wall-clock seconds since 1970, matching the client's deadline.
    /// Return once grants exist. Closing Settings after seeing it means refused;
    /// a pane that never launched is not a refusal. Abandoned clients stop waiting.
    /// Concurrent probes are awaited with deadline/cancellation checks even for
    /// passive gates, before any refusal or UI decision. A gate reentered by its
    /// own probe throws permissions_pending instead of deadlocking or denying.
    public func gate(deadline: TimeInterval, abandoned: () -> Bool = { false }, requestUI: Bool = true) throws {
        var shown: Kind?, settingsSeen = false
        while true {
            let snapshot = missing()
            let missing = snapshot.kinds
            guard let first = missing.first else { return }
            if !snapshot.pending.isEmpty {
                // A callback cannot make its own synchronous probe complete.
                // Report unknown explicitly; never turn reentry into a refusal.
                if snapshot.pending.contains(where: { $0.isCurrentThread }) {
                    if abandoned() { throw Errors.make("request_timed_out") }
                    throw Errors.make("permissions_pending", ["app": product, "grants": Self.names(missing)])
                }
                if calls.time() >= deadline - Self.giveUp { throw Errors.make("permissions_pending", ["app": product, "grants": Self.names(missing)]) }
                if abandoned() { throw Errors.make("request_timed_out") }
                if snapshot.pending.contains(where: { !$0.isFinished }) { calls.sleep(Self.poll) }
                continue
            }
            // Agent calls never request grants or open Settings. Only human controls do.
            if !requestUI { throw Errors.make("permissions_not_granted", ["grants": Self.names(missing), "app": product]) }
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
