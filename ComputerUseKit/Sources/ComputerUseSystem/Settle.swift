import Foundation
import ComputerUseCore
import os

/// Wait for the app's UI to go quiet and show no loading sign. The caller alone
/// decides when to wait; this module never reads or sets needsSettle.
public enum Settle {
    public static let pollNative = 0.1, pollWebLike = 0.25, quiet = 0.25, limit = 5.0
    public static let titleChanged = "AXTitleChanged"
    public static let notifications = [titleChanged, "AXLayoutChanged", "AXFocusedWindowChanged", "AXFocusedUIElementChanged", "AXElementBusyChanged", "AXMenuOpened", "AXSheetCreated", "AXWindowCreated", "AXCreated", "AXUIElementDestroyed"]

    // Only this recorder crosses onto the notification run loop. Title de-duping
    // and AX reads remain on the waiting FIFO worker, not inside a callback/lock.
    fileprivate final class Notifications: Sendable {
        struct State: Sendable {
            var last: TimeInterval
            var changes: [(TimeInterval, UIElementRef)] = []
        }
        let now: @Sendable () -> TimeInterval
        let state: OSAllocatedUnfairLock<State>
        init(now: @escaping @Sendable () -> TimeInterval) {
            self.now = now
            state = OSAllocatedUnfairLock(initialState: State(last: now()))
        }
        func note(_ name: String, element: UIElementRef) {
            let time = now()
            state.withLock {
                if name == Settle.titleChanged { $0.changes.append((time, element)) }
                else { $0.last = max($0.last, time) }
            }
        }
    }
    public final class Heard {
        fileprivate let notifications: Notifications
        private var titles: [(UIElementRef, String)] = []
        public init(now: @escaping @Sendable () -> TimeInterval) { notifications = Notifications(now: now) }
        /// Only store. Quiet starts before observation exists. May overlap quietFor.
        public func note(_ name: String, element: UIElementRef) { notifications.note(name, element: element) }
        /// Owned by the waiting FIFO worker; never called concurrently with itself.
        public func quietFor() -> TimeInterval {
            let pending = notifications.state.withLock {
                let pending = $0.changes; $0.changes.removeAll(); return pending
            }
            // An app that sends the same title forever must still go quiet.
            var counted: [TimeInterval] = []
            for (time, element) in pending {
                guard let title = (try? AX.backend.get(element, "AXTitle")) as? String else { continue }
                if let index = titles.firstIndex(where: { AX.same($0.0, element) }) {
                    if titles[index].1 != title { counted.append(time) }
                    titles[index].1 = title
                } else { titles.append((element, title)); counted.append(time) }
            }
            let latest = counted.max()
            let last = notifications.state.withLock {
                $0.last = max($0.last, latest ?? $0.last)
                return $0.last
            }
            return notifications.now() - last
        }
    }

    // HarnessExecutor supplies the reader, clears AppSession.needsSettle before
    // waiting, and reuses the returned capture instead of walking twice.
    public static func wait(target: AppTarget, kind: AppKind, read: (WindowRef) throws -> Capture,
                            poll: TimeInterval? = nil, quiet: TimeInterval = quiet, limit: TimeInterval = limit,
                            now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                            sleep: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
                            abandoned: () -> Bool = { false },
                            keyWindow: (AppTarget) throws -> WindowRef = Windows.keyWindow) throws -> Capture? {
        guard let pid = target.pid else { throw Errors.make("app_not_running", ["identifier": target.path]) }
        let heard = Heard(now: now)
        let backend = AX.backend
        let observer = try backend.observe(pid: pid, element: backend.app(pid: pid), names: notifications) { [recorder = heard.notifications] in recorder.note($0, element: $1) }
        defer { observer.stop() }
        let start = now(), interval = (poll == nil || poll == 0) ? (kind.webLike ? pollWebLike : pollNative) : poll!
        // Hard stop is checked before each sleep: one more poll and read may follow.
        while now() - start < limit {
            sleep(interval)
            if abandoned() { throw Errors.make("request_timed_out") }
            if heard.quietFor() < quiet { continue }
            let window: WindowRef
            do { window = try keyWindow(target) }
            catch let error as HarnessError where error.message == Errors.make("no_windows").message { continue }
            let capture = try read(window)
            if !capture.loading { return capture } // Print this capture: walk only once.
        }
        return nil
    }
}
