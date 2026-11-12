import ComputerUseCore
import Foundation
import os

/// What the person sees of the agent, as one seam. Each call hands work over and
/// returns at once, never throws. False means nothing was handed over (notably a
/// caller waiting for approval must know nobody will see its question).
/// Dependencies are immutable Sendable values and may be invoked concurrently.
/// No dependency runs under the pause lock. UI handoff still uses `schedule`;
/// this synchronous adapter does not change its caller's scheduling.
public final class Presence: Sendable {
    public static let shared = Presence(enabled: { Overlay.enabled() && MainThread.isRunning })
    // The person touched the app: stay paused whatever the calls in flight say.
    // Just under the 5 s after which the caller ends the pause.
    public static let pause = 4.75
    private let pausedUntil = OSAllocatedUnfairLock(initialState: 0.0)
    private let enabled: @Sendable () -> Bool, now: @Sendable () -> Double
    private let send: @Sendable (OverlayCommand) -> Void, schedule: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let show: @Sendable (Ask) -> Void, drop: @Sendable (String) -> Void
    public init(
        enabled: @escaping @Sendable () -> Bool = { Overlay.enabled() },
        now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
        send: @escaping @Sendable (OverlayCommand) -> Void = { Overlay.shared.send($0) },
        schedule: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { MainThread.onMain($0) },
        ask: @escaping @Sendable (Ask) -> Void = { ask in
            if MainThread.isRunning && Thread.isMainThread {
                MainActor.assumeIsolated { Panel.shared.append(ask) }
            }
        },
        withdraw: @escaping @Sendable (String) -> Void = { title in
            if MainThread.isRunning && Thread.isMainThread {
                MainActor.assumeIsolated { Panel.shared.withdraw(title: title) }
            }
        }
    ) {
        self.enabled = enabled
        self.now = now
        self.send = send
        self.schedule = schedule
        self.show = ask
        self.drop = withdraw
    }
    @discardableResult private func seen(_ command: OverlayCommand) -> Bool {
        guard enabled(), command.valid else { return false }
        send(command)
        return true
    }
    @discardableResult public func pointerMove(_ point: CGPoint, window: WindowRef? = nil) -> Bool {
        seen(.move(point, pid: window?.pid, window: Int(window?.windowID ?? 0)))
    }
    @discardableResult public func pointerPress(count: Int = 1) -> Bool { seen(.press(count)) }
    @discardableResult public func pointerActivity(_ state: String) -> Bool {
        guard enabled(), ["idle", "loading", "paused"].contains(state) else { return false }
        // Dependencies may reenter. Sample the clock before taking the state lock;
        // a delayed older sample must not shorten a newer human-input pause.
        let time = now()
        let suppressed = pausedUntil.withLock { until in
            if state == "paused" { until = max(until, time + Self.pause); return false }
            return time < until
        }
        if suppressed { return true }
        return seen(.activity(state))
    }
    @discardableResult public func flash(_ rect: CGRect, window: WindowRef? = nil) -> Bool {
        seen(
            .flash(
                rect, within: window?.frame, pid: window?.pid, window: Int(window?.windowID ?? 0)))
    }
    @discardableResult public func halo(_ window: WindowRef?) -> Bool {
        guard enabled() else { return false }
        if let window {
            return seen(.halo(window.frame, pid: window.pid, window: Int(window.windowID)))
        }
        return true
    }
    /// Upstream live_view is opt-in. No live-view transport in this port.
    @discardableResult public func liveView(_ window: WindowRef?) -> Bool { enabled() }
    @discardableResult public func turnDone() -> Bool {
        guard enabled() else { return false }
        pausedUntil.withLock { $0 = 0 }
        return seen(.done)
    }
    @discardableResult public func ask(_ question: Ask) -> Bool {
        guard enabled() else { return false }
        schedule { self.show(question) }
        return true
    }
    @discardableResult public func ask(
        title: String, subtitle: String? = nil, choices: [String],
        onAnswer: @escaping @Sendable (String) -> Void
    ) -> Bool { ask(Ask(title: title, subtitle: subtitle, choices: choices, onAnswer: onAnswer)) }
    @discardableResult public func withdraw(title: String) -> Bool {
        guard enabled() else { return false }
        schedule { self.drop(title) }
        return true
    }
}
