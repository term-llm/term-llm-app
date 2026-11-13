import Foundation
import os
import XCTest
@testable import ComputerUseCore

final class ModelOwnershipTests: XCTestCase {
    private func checked<Value: Sendable>(_ value: Value) -> Value { value }

    func testCheckedModelsSupportConcurrentPropertySnapshots() {
        let element = UIElementRef(El()), line = checked(ownershipLine())
        let capture = checked(ownershipCapture(line))
        let window = checked(WindowRef(element: element, windowID: 1, pid: 100, title: "Window", frame: .zero))
        DispatchQueue.concurrentPerform(iterations: 500) { index in
            line.depth = index
            line.text = "text \(index)"
            line.element = element
            line.role = "AXTextField"
            line.detail = "detail \(index)"
            line.name = "name \(index)"
            line.value = "value \(index)"
            line.match = ["match \(index)"]
            line.settable = index.isMultiple(of: 2)
            line.actions = [("Press", "AXPress")]
            line.id = index
            let snapshot = line.snapshot()
            XCTAssertNotNil(snapshot.element)
            XCTAssertEqual(snapshot.actions.first?.action, "AXPress")
            XCTAssertTrue(snapshot.text.hasPrefix("text "))

            capture.windowTitle = "Window \(index)"
            capture.appName = "App"
            capture.windowID = window.windowID
            capture.lines = [line]
            capture.focused = line
            capture.selectedText = "selection \(index)"
            capture.selected = [line]
            capture.menuOpen = index.isMultiple(of: 2)
            capture.loading = !index.isMultiple(of: 2)
            capture.url = "https://example.test/\(index)"
            let read = capture.snapshot()
            XCTAssertTrue(read.lines.first === line)
            XCTAssertTrue(read.focused === line)
            XCTAssertTrue(read.selected.first === line)
            XCTAssertEqual(read.windowID, 1)
        }
    }

    func testNumberingRetainsSharedLineAndCaptureIdentity() {
        let shared = ownershipLine(), outside = ownershipLine(), r = checked(Revisions())
        let capture = ownershipCapture(shared)
        capture.focused = shared
        capture.selected = [shared, outside]
        _ = r.present(capture)
        XCTAssertTrue(r.last === capture)
        XCTAssertTrue(capture.lines[0] === capture.focused)
        XCTAssertTrue(capture.lines[0] === capture.selected[0])
        XCTAssertEqual(shared.id, 0)
        XCTAssertEqual(outside.id, 1)
        let again = ownershipCapture(ownershipLine(shared.element!))
        _ = r.present(again)
        XCTAssertEqual(again.lines[0].id, shared.id)
    }

    func testConcurrentRevisionsOperationsAndNotificationRecording() throws {
        let backend = OwnershipAX(), r = Revisions(), element = UIElementRef(El())
        try AX.withBackend(backend) { try r.watch(demoTarget) }
        let observation = try XCTUnwrap(backend.observations.first)
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            AX.withBackend(backend) {
                let capture = ownershipCapture(ownershipLine(element))
                _ = r.present(capture)
                observation.fire(element)
                r.mark(Revisions.destroyed, element)
                _ = r.dead(element)
                do {
                    let line = try r.resolve(0, reread: { ownershipCapture(ownershipLine(element)) })
                    XCTAssertTrue(AX.same(line.element, element))
                } catch { XCTFail("Unexpected resolution failure at \(index): \(error)") }
                XCTAssertNotNil(r.last)
            }
        }
        XCTAssertEqual(backend.observations.count, 1)
        r.reset()
        XCTAssertTrue(observation.stopped)
    }

    func testConcurrentWatchResetPresentAndPropertyOwnership() {
        let backend = OwnershipAX(), r = Revisions(), element = UIElementRef(El())
        DispatchQueue.concurrentPerform(iterations: 300) { index in
            AX.withBackend(backend) {
                switch index % 5 {
                case 0: try? r.watch(demoTarget)
                case 1: r.reset()
                case 2: _ = r.present(ownershipCapture(ownershipLine(element)))
                case 3: r.mark(Revisions.destroyed, element)
                default: _ = r.dead(element); _ = r.last?.lines.first?.text
                }
            }
        }
        r.reset()
        XCTAssertNil(r.last)
        XCTAssertTrue(backend.observations.allSatisfy(\.stopped))
    }

    func testAppSessionConcurrentFieldsAndCancellationSnapshot() {
        let agent = AgentSession(key: "owner"), other = AgentSession(key: "other")
        let app = checked(AppSession(agent: agent, target: demoTarget)), r = Revisions()
        DispatchQueue.concurrentPerform(iterations: 500) { index in
            app.agent = index.isMultiple(of: 2) ? agent : other
            var target = demoTarget
            target.pid = pid_t(index)
            app.target = target
            app.active = index.isMultiple(of: 2)
            app.needsSettle = !index.isMultiple(of: 2)
            app.revisions = r
            app.shot = Shot(path: "fake", scale: 1, origin: .zero, width: index, height: 1)
            app.pageUnchecked = index.isMultiple(of: 2)
            app.cancel = { index.isMultiple(of: 2) }
            app.watching = target
            let currentAgent = app.agent
            XCTAssertTrue(currentAgent === agent || currentAgent === other)
            XCTAssertEqual(app.target.path, demoTarget.path)
            XCTAssertTrue(app.revisions === r)
            XCTAssertEqual(app.shot?.path, "fake")
            XCTAssertNotNil(app.watching)
            _ = app.cancel()
            _ = app.active; _ = app.needsSettle; _ = app.pageUnchecked
        }
        app.cancel = { [weak app] in
            app?.active = true
            app?.cancel = { false }
            return true
        }
        let original = app.cancel
        app.cancel = { false }
        XCTAssertTrue(original()) // snapshot, not the newly installed closure
        XCTAssertTrue(app.active)
        XCTAssertFalse(app.cancel()) // invocation reentered the session safely
    }

    func testCancellationCaptureIsReleasedOutsideSessionStateLock() {
        let app = AppSession(agent: AgentSession(key: "owner"), target: demoTarget)
        let released = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        do {
            let lifetime = OwnershipLifetime { [weak app] in
                XCTAssertEqual(app?.target, demoTarget)
                app?.active = true
                released.signal()
            }
            app.cancel = { [lifetime] in withExtendedLifetime(lifetime) { false } }
        }
        DispatchQueue.global().async { app.cancel = { true }; done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(released.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(app.active)
    }

    func testDisplacedModelHandleIsReleasedOutsideLineStateLock() {
        let line = ownershipLine(), released = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        line.element = UIElementRef(OwnershipLifetime { [weak line] in
            line?.text = "released"
            released.signal()
        })
        DispatchQueue.global().async { line.element = nil; done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(released.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(line.text, "released")
    }

    func testRefetchReleasesActualDisplacedHandleOutsideBothLocks() throws {
        let backend = OwnershipAX(), r = Revisions(), line = ownershipLine()
        let released = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        try AX.withBackend(backend) { try r.watch(demoTarget); _ = r.present(ownershipCapture(line)) }
        r.mark(Revisions.destroyed, line.element!)
        DispatchQueue.global().async {
            AX.withBackend(backend) {
                do {
                    let resolved = try r.resolve(0, reread: {
                        // This is not the handle retained in resolve's initial
                        // description snapshot. Its release must be deferred too.
                        line.element = UIElementRef(OwnershipLifetime {
                            XCTAssertNotNil(r.last)
                            line.text = "released"
                            released.signal()
                        })
                        return ownershipCapture(ownershipLine())
                    })
                    XCTAssertTrue(resolved === line)
                } catch { XCTFail("Unexpected refetch failure: \(error)") }
            }
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(released.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(line.text, "released")
    }

    func testReentrantRereadResetCannotRefetchIntoAnOldGeneration() throws {
        let backend = OwnershipAX(), r = Revisions(), oldLine = ownershipLine(), fresh = ownershipCapture(ownershipLine())
        let oldElement = oldLine.element
        try AX.withBackend(backend) {
            try r.watch(demoTarget)
            _ = r.present(ownershipCapture(oldLine))
            r.mark(Revisions.destroyed, oldElement!)
            XCTAssertThrowsError(try r.resolve(0, reread: {
                r.reset()
                try r.watch(demoTarget)
                _ = r.present(fresh)
                return ownershipCapture(ownershipLine())
            })) { error in
                XCTAssertEqual((error as? HarnessError)?.message, Errors.make("stale_element").message)
            }
            XCTAssertTrue(r.last === fresh)
            XCTAssertTrue(AX.same(oldLine.element, oldElement))
            XCTAssertTrue(try r.resolve(0, reread: { XCTFail("unexpected reread"); return fresh }) === fresh.lines[0])
        }
    }

    func testReentrantAliveCanResetWithoutHoldingState() throws {
        let backend = OwnershipAX(), r = Revisions()
        try AX.withBackend(backend) {
            try r.watch(demoTarget)
            _ = r.present(ownershipCapture(ownershipLine()))
            backend.onAlive = { _ in r.reset() }
            XCTAssertThrowsError(try r.resolve(0, reread: { XCTFail("unexpected reread"); return ownershipCapture(ownershipLine()) })) { error in
                XCTAssertEqual((error as? HarnessError)?.message, Errors.make("stale_element").message)
            }
            XCTAssertNil(r.last)
            XCTAssertTrue(backend.observations[0].stopped)
        }
    }

    func testDifferentPIDWatchDuringPresentCommitsNewNumberedCapture() throws {
        let backend = OwnershipAX(), r = Revisions(), armed = OSAllocatedUnfairLock(initialState: false)
        let watched = OSAllocatedUnfairLock(initialState: false)
        var next = demoTarget; next.pid = 200
        let nextTarget = next
        let hook: @Sendable () -> Void = { [weak r] in
            guard armed.withLock({ $0 }) else { return }
            let first = watched.withLock { value in let first = !value; value = true; return first }
            if first { try? r?.watch(nextTarget) }
        }
        let a = ownershipLine(), oldB = ownershipLine(UIElementRef(OwnershipEqualElement(hook)))
        oldB.text = "button B"
        let old = Capture(windowTitle: "Window", appName: "App", windowID: 1, lines: [a, oldB])
        let newA = ownershipLine(a.element!), newC = ownershipLine(UIElementRef(OwnershipEqualElement(hook)))
        newC.text = "button C"
        let fresh = Capture(windowTitle: "Window", appName: "App", windowID: 1, lines: [newA, newC])
        try AX.withBackend(backend) {
            try r.watch(demoTarget)
            _ = r.present(old)
            XCTAssertEqual(oldB.id, 1)
            armed.withLock { $0 = true }
            let text = r.present(fresh)
            XCTAssertTrue(watched.withLock { $0 })
            XCTAssertEqual(backend.observations.count, 2)
            XCTAssertTrue(backend.observations[0].stopped)
            XCTAssertEqual(newC.id, 1) // B's departed number is reused by C
            XCTAssertTrue(text.contains("1 button C"))
            XCTAssertTrue(r.last === fresh)
            let resolved = try r.resolve(1, reread: { XCTFail("unexpected reread"); return fresh })
            XCTAssertTrue(resolved === newC)
            XCTAssertFalse(resolved === oldB)
        }
    }

    func testEqualityIDNilWriterCannotInvalidateLocalNumberAssignment() {
        let r = Revisions(), victim = ownershipLine(), writes = OSAllocatedUnfairLock(initialState: 0)
        let first = ownershipLine(UIElementRef(OwnershipEqualElement {
            // given.firstIndex invokes CFEqual after numbering has read victim's
            // ID. The old code force-unwrapped a fresh property read afterwards.
            victim.id = nil
            writes.withLock { $0 += 1 }
        }))
        let capture = Capture(windowTitle: "Window", appName: "App", windowID: 1, lines: [first, victim])
        let text = r.present(capture)
        XCTAssertGreaterThan(writes.withLock { $0 }, 0)
        XCTAssertEqual(victim.id, 1)
        XCTAssertTrue(text.contains("1 text field Name"))
        XCTAssertTrue(r.last === capture)
    }

    func testPresentSelectionFootersMatchRenderFooter() {
        let fixtures: [(name: String, selectedText: String?)] = [
            ("selected text", "First line\nSecond line"),
            ("selected elements", nil),
        ]
        for fixture in fixtures {
            let r = Revisions(), shared = ownershipLine(), outside = ownershipLine()
            let capture = ownershipCapture(shared)
            capture.focused = shared
            capture.selected = [shared, outside]
            capture.selectedText = fixture.selectedText
            for _ in 0..<2 { // full presentation, then diff presentation
                let output = r.present(capture)
                let expected = Render.footer(capture, true)
                XCTAssertFalse(expected.isEmpty, fixture.name)
                XCTAssertTrue(output.hasSuffix(expected), fixture.name)
                XCTAssertTrue(r.last === capture, fixture.name)
                XCTAssertTrue(capture.lines[0] === capture.selected[0], fixture.name)
            }
        }
    }

    func testPresentRendersShallowCapturedReadRatherThanReplacedCaptureFields() {
        for diff in [false, true] {
            let r = Revisions(), kept = ownershipLine(), replacement = ownershipLine()
            kept.text = "text field Kept"
            replacement.text = "text field Replacement"
            let capture = ownershipCapture(kept), armed = OSAllocatedUnfairLock(initialState: false)
            let first = ownershipLine(UIElementRef(OwnershipEqualElement { [weak capture] in
                guard armed.withLock({ $0 }) else { return }
                capture?.windowTitle = "Changed"
                capture?.appName = "Other"
                capture?.lines = [replacement]
                capture?.focused = replacement
                capture?.selectedText = "changed selection"
            }))
            capture.lines = [first, kept]
            capture.focused = kept
            if diff { _ = r.present(capture) }
            armed.withLock { $0 = true }
            let text = r.present(capture)
            if diff { XCTAssertTrue(text.hasPrefix("Nothing changed in window \"Window\"")) }
            else {
                XCTAssertTrue(text.hasPrefix("Window: \"Window\", App: App."))
                XCTAssertTrue(text.contains("0 text field Name\n1 text field Kept"))
            }
            XCTAssertTrue(text.hasSuffix("The focused UI element is 1 text field Kept"))
            XCTAssertFalse(text.contains("Changed"))
            XCTAssertFalse(text.contains("Replacement"))
            XCTAssertFalse(text.contains("changed selection"))
            // No deep copy or replacement of public identity: only the rendered
            // read is stable. Coordinated writes still belong to the app FIFO.
            XCTAssertTrue(r.last === capture)
            XCTAssertTrue(r.last?.lines.first === replacement)
            XCTAssertTrue(r.last?.focused === replacement)
        }
    }

    func testReentrantEqualityCannotResurrectAResetCapture() {
        let r = Revisions(), comparisons = OSAllocatedUnfairLock(initialState: 0)
        let hook: @Sendable () -> Void = { comparisons.withLock { $0 += 1 }; r.reset() }
        let old = ownershipCapture(ownershipLine(UIElementRef(OwnershipEqualElement(hook))))
        _ = r.present(old)
        // CFEqual short-circuits identical pointers; distinct handles exercise the
        // injected NSObject equality implementation rather than that fast path.
        _ = r.present(ownershipCapture(ownershipLine(UIElementRef(OwnershipEqualElement(hook)))))
        XCTAssertGreaterThan(comparisons.withLock { $0 }, 0)
        XCTAssertNil(r.last)
    }

    func testReentrantObserveReservesSamePIDAndSupersededObserverIsStopped() throws {
        let backend = OwnershipAX(), r = Revisions(), fresh = ownershipCapture(ownershipLine())
        var next = demoTarget; next.pid = 200
        let nextTarget = next
        backend.onObserve = { [weak backend] _ in
            guard let backend else { XCTFail("backend released during observe"); return }
            backend.onObserve = nil
            // Simulate an injected synchronous hop to another thread, not UI work.
            // Neither an execution lock nor a state lock may block reset/watch.
            ownershipOnWorker {
                AX.withBackend(backend) {
                    r.reset()
                    try? r.watch(nextTarget)
                    _ = r.present(fresh)
                }
            }
        }
        try AX.withBackend(backend) { try r.watch(demoTarget); try r.watch(nextTarget) }
        XCTAssertEqual(backend.observations.count, 2)
        XCTAssertTrue(backend.observations[0].stopped)
        XCTAssertFalse(backend.observations[1].stopped)
        XCTAssertTrue(r.last === fresh)

        let same = OwnershipAX(), sameR = Revisions()
        same.onObserve = { _ in try? sameR.watch(demoTarget) }
        try AX.withBackend(same) { try sameR.watch(demoTarget) }
        XCTAssertEqual(same.observations.count, 1)
    }

    func testReentrantObserveFailureDoesNotRemoveNewerMonitor() throws {
        let backend = OwnershipAX(), r = Revisions(), fresh = ownershipCapture(ownershipLine())
        var next = demoTarget; next.pid = 200
        let nextTarget = next
        backend.failObserve = true
        backend.onObserve = { [weak backend] _ in
            backend?.onObserve = nil
            backend?.failObserve = false
            r.reset()
            try? r.watch(nextTarget)
            _ = r.present(fresh)
        }
        try AX.withBackend(backend) {
            XCTAssertThrowsError(try r.watch(demoTarget))
            try r.watch(nextTarget)
            XCTAssertTrue(try r.resolve(0, reread: { XCTFail("unexpected reread"); return fresh }) === fresh.lines[0])
        }
        XCTAssertEqual(backend.observations.count, 1)
        XCTAssertFalse(backend.observations[0].stopped)
    }

    func testReentrantStopDoesNotOverwriteLaterWatchOrHoldState() throws {
        let backend = OwnershipAX(), r = Revisions(), fresh = ownershipCapture(ownershipLine())
        var middle = demoTarget; middle.pid = 200
        var next = demoTarget; next.pid = 300
        let nextTarget = next
        backend.onStop = { [weak backend, weak r] in
            guard let backend, let r else { return }
            backend.onStop = nil
            ownershipOnWorker {
                AX.withBackend(backend) {
                    try? r.watch(nextTarget)
                    _ = r.present(fresh)
                }
            }
        }
        try AX.withBackend(backend) { try r.watch(demoTarget); try r.watch(middle); try r.watch(nextTarget) }
        XCTAssertEqual(backend.observations.count, 2) // middle reservation was superseded during stop
        XCTAssertTrue(backend.observations[0].stopped)
        XCTAssertFalse(backend.observations[1].stopped)
        XCTAssertTrue(r.last === fresh)
    }

    func testClaimedOldCallbackCannotInvalidateLaterWatchOrResetGeneration() throws {
        let backend = OwnershipAX(), r = Revisions(), element = UIElementRef(El())
        try AX.withBackend(backend) {
            try r.watch(demoTarget)
            let old = backend.observations[0], claimed = try XCTUnwrap(old.claim())
            r.reset()
            try r.watch(demoTarget)
            _ = r.present(ownershipCapture(ownershipLine(element)))
            claimed(Revisions.destroyed, element) // claimed before teardown, finishes afterwards
            XCTAssertTrue(old.stopped)
            XCTAssertFalse(r.dead(element))
            backend.observations[1].fire(element)
            XCTAssertTrue(r.dead(element))
            var next = demoTarget; next.pid = 200
            let secondClaim = try XCTUnwrap(backend.observations[1].claim())
            try r.watch(next)
            secondClaim(Revisions.destroyed, element)
            XCTAssertFalse(r.dead(element))
            backend.observations[2].fire(element)
            XCTAssertTrue(r.dead(element))
            _ = r.present(ownershipCapture(ownershipLine(element)))
            XCTAssertFalse(r.dead(element)) // a fresh read still clears current marks
        }
    }

    func testBlockedRefetchDoesNotBlockNotificationsResetOrAnotherApp() throws {
        let backend = OwnershipAX(), r = Revisions(), other = Revisions(), element = UIElementRef(El())
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        try AX.withBackend(backend) { try r.watch(demoTarget); _ = r.present(ownershipCapture(ownershipLine(element))) }
        r.mark(Revisions.destroyed, element)
        DispatchQueue.global().async {
            AX.withBackend(backend) {
                do {
                    _ = try r.resolve(0, reread: {
                        entered.signal()
                        guard resume.wait(timeout: .now() + 5) == .success else { throw Errors.serverError("reread timed out") }
                        return ownershipCapture(ownershipLine())
                    })
                    XCTFail("reset during reread must invalidate resolution")
                } catch { XCTAssertEqual((error as? HarnessError)?.message, Errors.make("stale_element").message) }
            }
            done.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        backend.observations[0].fire(element)
        XCTAssertTrue(AX.withBackend(backend) { r.dead(element) })
        r.reset()
        _ = other.present(ownershipCapture(ownershipLine()))
        XCTAssertNotNil(other.last)
        resume.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertNil(r.last)
    }

    func testResetStopCanReenterRevisionsState() throws {
        let r = Revisions(), backend = OwnershipAX(), stopped = OSAllocatedUnfairLock(initialState: 0)
        backend.onStop = { [weak r] in
            XCTAssertNotNil(r)
            XCTAssertNil(r?.last) // really enters Revisions state during reset's stop
            stopped.withLock { $0 += 1 }
        }
        try AX.withBackend(backend) { try r.watch(demoTarget) }
        _ = r.present(ownershipCapture(ownershipLine()))
        r.reset()
        XCTAssertEqual(stopped.withLock { $0 }, 1)
    }

    func testDeinitStopOutsideSessionReplacementLock() throws {
        let app = AppSession(agent: AgentSession(key: "owner"), target: demoTarget), backend = OwnershipAX()
        let stopped = OSAllocatedUnfairLock(initialState: 0)
        backend.onStop = { [weak app] in
            XCTAssertNotNil(app)
            XCTAssertNil(app?.revisions) // reenters AppSession's replacement lock
            app?.watching = nil
            stopped.withLock { $0 += 1 }
        }
        try AX.withBackend(backend) {
            let r = Revisions()
            try r.watch(demoTarget)
            app.revisions = r
        }
        app.revisions = nil // final release invokes Revisions.deinit and observation.stop
        XCTAssertEqual(stopped.withLock { $0 }, 1)
    }
}

private func ownershipOnWorker(_ work: @escaping @Sendable () -> Void) {
    let done = DispatchSemaphore(value: 0)
    // Unlike queue.sync (which may execute inline), this proves that the caller
    // can wait for reentrant work on a different thread without holding a lock
    // needed by that work. No real main-run-loop, AX, or UI operations occur.
    DispatchQueue.global().async { work(); done.signal() }
    XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
}

private func ownershipLine(_ element: UIElementRef = UIElementRef(El())) -> Line {
    Line(depth: 0, text: "text field Name", element: element, role: "AXTextField", match: ["AXTextField", "Name"])
}
private func ownershipCapture(_ line: Line) -> Capture {
    Capture(windowTitle: "Window", appName: "App", windowID: 1, lines: [line])
}
private final class OwnershipLifetime: Sendable {
    let action: @Sendable () -> Void
    init(_ action: @escaping @Sendable () -> Void) { self.action = action }
    deinit { action() }
}
private final class OwnershipEqualElement: El {
    let action: @Sendable () -> Void
    init(_ action: @escaping @Sendable () -> Void) { self.action = action; super.init() }
    override func isEqual(_ object: Any?) -> Bool {
        action()
        return self === (object as AnyObject?)
    }
    override var hash: Int { 1 }
}

/// A fake with explicit claim/finish separation, mirroring AXObservation's allowed
/// late completion, plus hooks that run only after releasing its typed locks.
private final class OwnershipObservation: AXObservation {
    private let open = OSAllocatedUnfairLock(initialState: true)
    private let callback: @Sendable (String, UIElementRef) -> Void
    private let onStop: (@Sendable () -> Void)?
    init(_ callback: @escaping @Sendable (String, UIElementRef) -> Void, onStop: (@Sendable () -> Void)?) {
        self.callback = callback; self.onStop = onStop
    }
    var stopped: Bool { open.withLock { !$0 } }
    func claim() -> (@Sendable (String, UIElementRef) -> Void)? { open.withLock { $0 } ? callback : nil }
    func fire(_ element: UIElementRef) { claim()?(Revisions.destroyed, element) }
    func stop() {
        let claimed = open.withLock { value in let old = value; value = false; return old }
        if claimed { onStop?() }
    }
}

private final class OwnershipAX: AXBackend {
    private struct State: Sendable {
        var observations: [OwnershipObservation] = []
        var onObserve: (@Sendable (pid_t) -> Void)?
        var onStop: (@Sendable () -> Void)?
        var onAlive: (@Sendable (UIElementRef) -> Void)?
        var failObserve = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let base = FakeAX()
    var observations: [OwnershipObservation] { state.withLock { $0.observations } }
    var onObserve: (@Sendable (pid_t) -> Void)? {
        get { state.withLock { $0.onObserve } }
        set { state.replaceModelValue(\.onObserve, with: newValue) }
    }
    var onStop: (@Sendable () -> Void)? {
        get { state.withLock { $0.onStop } }
        set { state.replaceModelValue(\.onStop, with: newValue) }
    }
    var onAlive: (@Sendable (UIElementRef) -> Void)? {
        get { state.withLock { $0.onAlive } }
        set { state.replaceModelValue(\.onAlive, with: newValue) }
    }
    var failObserve: Bool {
        get { state.withLock { $0.failObserve } }
        set { state.withLock { $0.failObserve = newValue } }
    }
    func observe(pid: pid_t, element: UIElementRef, names: [String], callback: @escaping @Sendable (String, UIElementRef) -> Void) throws -> any AXObservation {
        let before = state.withLock { $0 }
        if before.failObserve {
            before.onObserve?(pid)
            throw AX.failure(AX.invalidElement)
        }
        let observation = OwnershipObservation(callback, onStop: before.onStop)
        state.withLock { $0.observations.append(observation) }
        before.onObserve?(pid)
        return observation
    }
    func alive(_ element: UIElementRef) -> Bool { onAlive?(element); return base.alive(element) }
    func app(pid: pid_t) -> UIElementRef { base.app(pid: pid) }
    func get(_ element: UIElementRef, _ name: String) throws -> Any? { try base.get(element, name) }
    func names(_ element: UIElementRef) -> [String] { base.names(element) }
    func getMany(_ element: UIElementRef, _ names: [String]) throws -> [Any?] { try base.getMany(element, names) }
    func set(_ element: UIElementRef, _ name: String, _ value: Any) throws { try base.set(element, name, value) }
    func settable(_ element: UIElementRef, _ name: String) -> Bool { base.settable(element, name) }
    func actionNames(_ element: UIElementRef) -> [String] { base.actionNames(element) }
    func actionDescription(_ element: UIElementRef, _ action: String) -> String { base.actionDescription(element, action) }
    func perform(_ element: UIElementRef, _ action: String) throws { try base.perform(element, action) }
    func param(_ element: UIElementRef, _ name: String, _ argument: Any) -> Any? { base.param(element, name, argument) }
    func pid(_ element: UIElementRef) throws -> pid_t { try base.pid(element) }
    func windowID(_ element: UIElementRef) -> UInt32 { base.windowID(element) }
    func frame(_ element: UIElementRef) -> CGRect? { base.frame(element) }
    func at(_ app: UIElementRef?, x: Double, y: Double) -> UIElementRef? { nil }
}
