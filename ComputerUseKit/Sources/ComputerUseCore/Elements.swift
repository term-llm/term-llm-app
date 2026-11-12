import Foundation
import os

/// Numbers for one app as one agent saw it. Numbers belong to elements as long as
/// they remain paired. New elements count after the largest number that stayed,
/// so a departed number can later be used by another element.
public final class Revisions {
    public static let destroyed = "AXUIElementDestroyed"
    public private(set) var last: Capture?
    private var observer: AXObservation?
    private var pid: pid_t?
    // Only this recorder crosses onto the notification run loop. Capture/numbering
    // and observer ownership remain confined to the session's FIFO worker.
    private var destroyedElements = OSAllocatedUnfairLock(initialState: [UIElementRef]())
    public init() {}
    private struct Same: Equatable {
        var element: UIElementRef?
        static func == (a: Same, b: Same) -> Bool { AX.same(a.element, b.element) }
    }
    private func extra(_ capture: Capture) -> [Line] { (capture.focused.map { [$0] } ?? []) + capture.selected }
    private func full(_ capture: Capture, _ footer: String) -> String {
        Render.header(capture.windowTitle, capture.appName) + "\n" + capture.lines.map(Diff.line).joined(separator: "\n") + "\n" + (footer.isEmpty ? "" : "\n" + footer)
    }
    public func present(_ capture: Capture, disableDiff: Bool = false) -> String {
        let old = disableDiff ? nil : last
        let lines = capture.lines
        if let old {
            for change in Diff.pair(old.lines, lines, key: { Same(element: $0.element) }) {
                if let previous = change.old { change.lines[0].id = previous.id }
            }
        } else {
            for (number, node) in lines.enumerated() { node.id = number }
        }
        var fresh = (lines.compactMap { $0.id }.max() ?? 0) + 1
        var given: [(Same, Int)] = []
        for node in lines + extra(capture) {
            let key = Same(element: node.element)
            if node.id == nil {
                if let number = given.first(where: { $0.0 == key })?.1 { node.id = number }
                else { node.id = fresh; fresh += 1 }
            }
            if let at = given.firstIndex(where: { $0.0 == key }) { given[at].1 = node.id! }
            else { given.append((key, node.id!)) }
        }
        let footer = Render.footer(capture, true)
        let text = old.flatMap { Diff.text(Diff.pair($0.lines, lines, key: { $0.id }), capture.windowTitle, footer, lines.count) }
        last = capture
        destroyedElements.withLock { $0.removeAll() }
        return text ?? full(capture, footer)
    }
    /// The line with this number, alive or refetched by its printed description.
    /// ignoreValue is used when a tool itself may already have changed the value.
    public func resolve(_ index: Int, reread: () throws -> Capture, ignoreValue: Bool = false) throws -> Line {
        let known = last.map { $0.lines + extra($0) } ?? []
        guard let line = known.first(where: { $0.id == index }) else { throw Errors.make("invalid_element_id", ["index": String(index)]) }
        guard observer != nil else { throw Errors.make("no_invalidation_monitor") }
        if let element = line.element, !dead(element) { return line }
        func alike(_ node: Line) -> Bool { ReadString.equal(node.match, line.match) && (ignoreValue || ReadString.equal(node.value, line.value)) }
        if known.contains(where: { alike($0) && !AX.same($0.element, line.element) }) { throw Errors.ambiguousRefetch(started: false) }
        let found = try reread().lines.filter(alike)
        if found.isEmpty { throw Errors.make("stale_element") }
        if found.count > 1 { throw Errors.ambiguousRefetch(started: true) }
        line.element = found[0].element
        return line
    }
    /// Start marking destroyed elements. Repeated calls for the same pid are free.
    public func watch(_ target: AppTarget) throws {
        if observer != nil && pid == target.pid { return }
        stop()
        let backend = AX.backend
        let app = backend.app(pid: target.pid ?? 0)
        observer = try backend.observe(pid: target.pid ?? 0, element: app, names: [Self.destroyed]) { [destroyedElements] _, element in
            destroyedElements.withLock { $0.append(element) }
        }
        pid = target.pid
    }
    public func reset() { stop(); last = nil }
    public func mark(_ name: String, _ element: UIElementRef) {
        destroyedElements.withLock { $0.append(element) }
    }
    public func dead(_ element: UIElementRef) -> Bool {
        let destroyed = destroyedElements.withLock { $0 }
        return destroyed.contains { AX.same(element, $0) } || !AX.backend.alive(element)
    }
    private func stop() {
        observer?.stop(); observer = nil; pid = nil
        // A callback claimed before stop may finish later. Its old recorder must
        // not invalidate a subsequent watch/reset generation.
        destroyedElements = OSAllocatedUnfairLock(initialState: [])
    }
    deinit { observer?.stop() }
}
