import ComputerUseCore
import Foundation

/// What the person sees of the agent, as one seam. Each call hands work over and
/// returns at once, never throws. False means nothing was handed over (notably a
/// caller waiting for approval must know nobody will see its question).
public final class Presence {
    public static let shared = Presence(enabled: { Overlay.enabled() && MainThread.isRunning })
    // The person touched the app: stay paused whatever the calls in flight say.
    // Just under the 5 s after which the caller ends the pause.
    public static let pause = 4.75
    private let lock = NSLock()
    private var pausedUntil = 0.0
    private let enabled: () -> Bool, now: () -> Double
    private let send: (OverlayCommand) -> Void, schedule: (@escaping @Sendable () -> Void) -> Void
    private let show: (Ask) -> Void, drop: (String) -> Void
    public init(
        enabled: @escaping () -> Bool = { Overlay.enabled() },
        now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
        send: @escaping (OverlayCommand) -> Void = { Overlay.shared.send($0) },
        schedule: @escaping (@escaping @Sendable () -> Void) -> Void = MainThread.onMain,
        ask: @escaping (Ask) -> Void = { ask in
            if MainThread.isRunning && Thread.isMainThread {
                MainActor.assumeIsolated { Panel.shared.append(ask) }
            }
        },
        withdraw: @escaping (String) -> Void = { title in
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
        lock.lock()
        let time = now()
        if state == "paused" {
            pausedUntil = time + Self.pause
        } else if time < pausedUntil {
            lock.unlock()
            return true
        }
        lock.unlock()
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
        lock.lock()
        pausedUntil = 0
        lock.unlock()
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
