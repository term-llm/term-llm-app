import Foundation
import ComputerUseCore

/// Wait for the app's UI to go quiet and show no loading sign. The caller alone
/// decides when to wait; this module never reads or sets needsSettle.
public enum Settle {
    public static let pollNative = 0.1, pollWebLike = 0.25, quiet = 0.25, limit = 5.0
    public static let titleChanged = "AXTitleChanged"
    public static let notifications = [titleChanged, "AXLayoutChanged", "AXFocusedWindowChanged", "AXFocusedUIElementChanged", "AXElementBusyChanged", "AXMenuOpened", "AXSheetCreated", "AXWindowCreated", "AXCreated", "AXUIElementDestroyed"]

    public final class Heard {
        let now: () -> TimeInterval
        let lock = NSLock()
        var last: TimeInterval
        var changes: [(TimeInterval, UIElementRef)] = []
        var titles: [(UIElementRef, String)] = []
        public init(now: @escaping () -> TimeInterval) { self.now = now; last = now() }
        /// On the main run loop: only store. Quiet starts before observation exists.
        public func note(_ name: String, element: UIElementRef) {
            let time = now()
            lock.lock(); defer { lock.unlock() }
            if name == Settle.titleChanged { changes.append((time, element)) }
            else { last = max(last, time) }
        }
        public func quietFor() -> TimeInterval {
            lock.lock(); let pending = changes; changes = []; lock.unlock()
            // An app that sends the same title forever must still go quiet.
            var counted: [TimeInterval] = []
            for (time, element) in pending {
                guard let title = (try? AX.backend.get(element, "AXTitle")) as? String else { continue }
                if let index = titles.firstIndex(where: { AX.same($0.0, element) }) {
                    if titles[index].1 != title { counted.append(time) }
                    titles[index].1 = title
                } else { titles.append((element, title)); counted.append(time) }
            }
            lock.lock(); defer { lock.unlock() }
            last = max(last, counted.max() ?? last)
            return now() - last
        }
    }

    // HarnessExecutor supplies the reader, clears AppSession.needsSettle before
    // waiting, and reuses the returned capture instead of walking twice.
    public static func wait(target: AppTarget, kind: AppKind, read: (WindowRef) throws -> Capture,
                            poll: TimeInterval? = nil, quiet: TimeInterval = quiet, limit: TimeInterval = limit,
                            now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                            sleep: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
                            abandoned: () -> Bool = { false },
                            keyWindow: (AppTarget) throws -> WindowRef = Windows.keyWindow) throws -> Capture? {
        guard let pid = target.pid else { throw Errors.make("app_not_running", ["identifier": target.path]) }
        let heard = Heard(now: now)
        let observer = try AX.backend.observe(pid: pid, element: AX.backend.app(pid: pid), names: notifications) { heard.note($0, element: $1) }
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
