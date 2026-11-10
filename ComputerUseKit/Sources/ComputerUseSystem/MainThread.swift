import AppKit
import Foundation

/// The one way onto the helper's main thread, where AppKit lives (macos-harness
/// runloop.py). With no run loop started (tests) `onMain` and `callOnMain` run the
/// work at once on the caller's thread.
public enum MainThread {
    private static let state = RunningFlag()

    public static var isRunning: Bool { state.value }

    /// Run `work` soon on the main thread. Do not wait for it.
    public static func onMain(_ work: @escaping () -> Void) {
        guard state.value else {
            work()
            return
        }
        OperationQueue.main.addOperation(work)
    }

    /// Run `work` on the main thread, wait, and return or rethrow what it did.
    public static func callOnMain<T>(_ work: @escaping () throws -> T) rethrows -> T {
        if !state.value || Thread.isMainThread { return try work() }
        var result: Result<T, Error>!
        let done = DispatchSemaphore(value: 0)
        OperationQueue.main.addOperation {
            result = Result { try work() }
            done.signal()
        }
        done.wait()
        // `rethrows` can't see through the Result: only `work` throws here.
        return try { () throws -> T in try result.get() }()
    }

    /// Run the AppKit loop as an accessory app (no Dock icon) until `stop()`. `then`
    /// runs on the main thread once the loop runs: start there every thread that may
    /// call `onMain`.
    public static func run(then: @escaping () -> Void) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        OperationQueue.main.addOperation {
            state.value = true
            then()
        }
        app.run()
        state.value = false
    }

    /// Make `run()` return. Any thread may call it.
    public static func stop() {
        guard state.value else { return }
        onMain {
            let app = NSApplication.shared
            app.stop(nil)
            // stop() takes effect after the next event, so send one.
            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                             timestamp: 0, windowNumber: 0, context: nil,
                                             subtype: 0, data1: 0, data2: 0) {
                app.postEvent(wake, atStart: true)
            }
        }
    }
}

final class RunningFlag: @unchecked Sendable {
    private var stored = false
    private let lock = NSLock()

    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
