import AppKit
import Foundation
import os

/// The one way onto the helper's main thread, where AppKit lives (macos-harness
/// runloop.py). With no run loop started (tests) `onMain` and `callOnMain` run the
/// work at once on the caller's thread.
public enum MainThread {
    private static let running = OSAllocatedUnfairLock(initialState: false)

    public static var isRunning: Bool { running.withLock { $0 } }

    /// Run `work` soon on the main thread. Do not wait for it.
    public static func onMain(_ work: @escaping @Sendable () -> Void) {
        guard isRunning else {
            work()
            return
        }
        OperationQueue.main.addOperation(work)
    }

    /// Run `work` on the main thread, wait, and return or rethrow what it did.
    /// The caller is blocked meanwhile, so `work` and its result never run
    /// concurrently with the caller.
    public static func callOnMain<T>(_ work: () throws -> T) rethrows -> T {
        if !isRunning || Thread.isMainThread { return try work() }
        return try DispatchQueue.main.sync(execute: work)
    }

    /// Run the AppKit loop as an accessory app (no Dock icon) until `stop()`. `then`
    /// runs on the main thread once the loop runs: start there every thread that may
    /// call `onMain`.
    @MainActor
    public static func run(then: @escaping @MainActor () -> Void) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        OperationQueue.main.addOperation {
            running.withLock { $0 = true }
            MainActor.assumeIsolated(then)  // Operations on the main queue run on the main thread.
        }
        app.run()
        running.withLock { $0 = false }
    }

    /// Make `run()` return. Any thread may call it.
    public static func stop() {
        guard isRunning else { return }
        onMain {
            // Run inline off the main thread only if the loop stopped meanwhile: nothing left to stop.
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated {
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
}
