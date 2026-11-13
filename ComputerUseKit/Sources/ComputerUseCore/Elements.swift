import Foundation
import os

/// Numbers for one app as one agent saw it. Numbers belong to elements as long as
/// they remain paired. New elements count after the largest number that stayed,
/// so a departed number can later be used by another element.
public final class Revisions: Sendable {
    public static let destroyed = "AXUIElementDestroyed"

    // Only this generation's recorder crosses onto the notification run loop.
    // A callback already claimed at stop can finish, but cannot mark a later watch.
    private final class Generation: Sendable {
        let destroyed = OSAllocatedUnfairLock(initialState: [UIElementRef]())
    }
    private struct State: Sendable {
        var last: Capture?
        var version: UInt64 = 0
        var observer: (any AXObservation)?
        var pid: pid_t?
        // True during observe as well as after installation: a reentrant watch of
        // the same pid must not recursively install a second observation.
        var watching = false
        var generation = Generation()
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    // Intentional per-instance coherence for numbering/diff/refetch, distinct from
    // the short state lock. Recursive for synchronous injected reread/equality.
    // Notification callbacks, watch and reset NEVER require this lock; observe or
    // stop can hop to main or reenter lifetime operations without waiting for it.
    private let execution = NSRecursiveLock()
    public var last: Capture? { state.withLock { $0.last } }
    public init() {}

    private struct Same: Equatable {
        var element: UIElementRef?
        static func == (a: Same, b: Same) -> Bool { AX.same(a.element, b.element) }
    }
    private func extra(_ capture: Capture.Snapshot) -> [Line] { (capture.focused.map { [$0] } ?? []) + capture.selected }
    private func full(_ capture: Capture.Snapshot, _ footer: String) -> String {
        Render.header(capture.windowTitle, capture.appName) + "\n" + capture.lines.map(Diff.line).joined(separator: "\n") + "\n" + (footer.isEmpty ? "" : "\n" + footer)
    }
    // Same footer formatting as Render.footer, but use this operation's shallow
    // capture read rather than rereading independently mutable Capture fields.
    private func footer(_ capture: Capture.Snapshot) -> String {
        if let text = capture.selectedText, !text.isEmpty { return "Selected text: ```\n\(text)\n```\n\n\(Render.note)" }
        if !capture.selected.isEmpty { return "Selected:\n" + capture.selected.map { "\t" + Render.numbered($0, true) }.joined(separator: "\n") + "\n\n" + Render.note }
        if let focused = capture.focused { return "The focused UI element is " + Render.numbered(focused, true) }
        return ""
    }
    public func present(_ capture: Capture, disableDiff: Bool = false) -> String {
        execution.lock(); defer { execution.unlock() }
        let before = state.withLock { $0 }
        let old = disableDiff ? nil : before.last?.snapshot()
        let read = capture.snapshot()
        let lines = read.lines
        if let old {
            for change in Diff.pair(old.lines, lines, key: { Same(element: $0.element) }) {
                if let previous = change.old { change.lines[0].id = previous.id }
            }
        } else {
            for (number, node) in lines.enumerated() { node.id = number }
        }
        var fresh = (lines.compactMap { $0.id }.max() ?? 0) + 1
        var given: [(Same, Int)] = []
        for node in lines + extra(read) {
            let key = Same(element: node.element)
            let assignedID: Int
            if let number = node.id { assignedID = number }
            else if let number = given.first(where: { $0.0 == key })?.1 { assignedID = number }
            else { assignedID = fresh; fresh += 1 }
            if let at = given.firstIndex(where: { $0.0 == key }) { given[at].1 = assignedID }
            else { given.append((key, assignedID)) }
            // Equality above can reenter a property writer. Keep the local ID
            // across callbacks, then publish it once without force-unwrapping.
            node.id = assignedID
        }
        let footer = footer(read)
        let text = old.flatMap { Diff.text(Diff.pair($0.lines, lines, key: { $0.id }), read.windowTitle, footer, lines.count) }
        // CFEqual above is injected code too. A reentrant reset/present changes
        // version and must win. Watch only changes observer generation, not last:
        // it must not leave these newly printed IDs resolving into the old read.
        let committed = state.withLock { current in
            guard current.version == before.version else { return false }
            current.last = capture
            current.version &+= 1
            return true
        }
        if committed { before.generation.destroyed.replaceModelValue(\.self, with: []) }
        withExtendedLifetime(before) {} // displaced graph is released outside state
        return text ?? full(read, footer)
    }
    /// The line with this number, alive or refetched by its printed description.
    /// ignoreValue is used when a tool itself may already have changed the value.
    public func resolve(_ index: Int, reread: () throws -> Capture, ignoreValue: Bool = false) throws -> Line {
        execution.lock(); defer { execution.unlock() }
        let before = state.withLock { $0 }
        let read = before.last?.snapshot()
        let known = read.map { $0.lines + extra($0) } ?? []
        guard let line = known.first(where: { $0.id == index }) else { throw Errors.make("invalid_element_id", ["index": String(index)]) }
        guard before.observer != nil else { throw Errors.make("no_invalidation_monitor") }
        let description = line.snapshot()
        if let element = description.element, !dead(element, generation: before.generation) {
            guard isCurrent(before) else { throw Errors.make("stale_element") }
            return line
        }
        func alike(_ node: Line) -> Bool {
            let candidate = node.snapshot()
            return ReadString.equal(candidate.match, description.match) && (ignoreValue || ReadString.equal(candidate.value, description.value))
        }
        if known.contains(where: { alike($0) && !AX.same($0.element, description.element) }) { throw Errors.ambiguousRefetch(started: false) }
        let found = try reread().lines.filter(alike)
        if found.isEmpty { throw Errors.make("stale_element") }
        if found.count > 1 { throw Errors.ambiguousRefetch(started: true) }
        let element = found[0].element
        let commit: (accepted: Bool, displaced: UIElementRef?) = state.withLock { current in
            guard current.version == before.version, current.generation === before.generation else { return (false, nil) }
            let displaced = line.exchangeElement(element)
            current.version &+= 1
            return (true, displaced)
        }
        // Retain the actual displaced SDK handle, even if a concurrent property
        // writer changed it since description was snapshotted. Never deinit it
        // under either the Line lock or the enclosing Revisions state lock.
        withExtendedLifetime(commit.displaced) {}
        guard commit.accepted else { throw Errors.make("stale_element") }
        return line
    }
    private func isCurrent(_ before: State) -> Bool {
        state.withLock { $0.version == before.version && $0.generation === before.generation }
    }
    /// Start marking destroyed elements. Repeated calls for the same pid are free.
    public func watch(_ target: AppTarget) throws {
        // Reserve before doing external work. No state lock spans app, observe,
        // stop, or any main hop. Reset/reentrant watch may supersede this token.
        let reservation: (State, Generation)? = state.withLock { current in
            if current.watching && current.pid == target.pid { return nil }
            let old = current
            current.observer = nil
            current.pid = target.pid
            current.watching = true
            current.generation = Generation()
            return (old, current.generation)
        }
        guard let (old, generation) = reservation else { return }
        old.observer?.stop()
        guard state.withLock({ $0.generation === generation }) else { return }
        let backend = AX.backend
        do {
            let app = backend.app(pid: target.pid ?? 0)
            guard state.withLock({ $0.generation === generation }) else { return }
            let observer = try backend.observe(pid: target.pid ?? 0, element: app, names: [Self.destroyed]) { _, element in
                generation.destroyed.withLock { $0.append(element) }
            }
            let installed = state.withLock { current in
                guard current.generation === generation else { return false }
                current.observer = observer
                return true
            }
            if !installed { observer.stop() }
        } catch {
            state.withLock { current in
                if current.generation === generation { current.watching = false; current.pid = nil }
            }
            throw error
        }
        withExtendedLifetime(old) {}
    }
    public func reset() {
        let old = state.withLock { current in
            let old = current
            current.last = nil
            current.version &+= 1
            current.observer = nil
            current.pid = nil
            current.watching = false
            current.generation = Generation()
            return old
        }
        old.observer?.stop()
        withExtendedLifetime(old) {}
    }
    public func mark(_ name: String, _ element: UIElementRef) {
        let generation = state.withLock { $0.generation }
        generation.destroyed.withLock { $0.append(element) }
    }
    public func dead(_ element: UIElementRef) -> Bool {
        dead(element, generation: state.withLock { $0.generation })
    }
    private func dead(_ element: UIElementRef, generation: Generation) -> Bool {
        let destroyed = generation.destroyed.withLock { $0 }
        return destroyed.contains { AX.same(element, $0) } || !AX.backend.alive(element)
    }
    deinit { state.withLock { $0.observer }?.stop() }
}
