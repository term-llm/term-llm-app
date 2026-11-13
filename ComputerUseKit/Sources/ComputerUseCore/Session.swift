import Foundation
import os

/// One app as one agent sees it. Lives in the helper between calls.
/// The lock protects field ownership, not logical transactions. The canonical
/// per-app FIFO must still serialize multi-step reads/actions/lifecycle operations;
/// even a read-modify-write expression on one property is not a transaction.
public final class AppSession: Sendable {
    private struct State: Sendable {
        var agent: AgentSession
        var target: AppTarget
        var active = false
        var needsSettle = false
        var revisions: Revisions?
        var shot: Shot?
        var pageUnchecked = false
        var cancel: @Sendable () -> Bool = { false }
        var watching: AppTarget?
    }
    private let state: OSAllocatedUnfairLock<State>

    public var agent: AgentSession {
        get { state.withLock { $0.agent } }
        set { state.replaceModelValue(\.agent, with: newValue) }
    }
    /// Also snapshotted by panel ownership and turn reaping before taking an app FIFO.
    public var target: AppTarget {
        get { state.withLock { $0.target } }
        set { state.replaceModelValue(\.target, with: newValue) }
    }
    /// A state read succeeded since the session or the turn began.
    public var active: Bool {
        get { state.withLock { $0.active } }
        set { state.replaceModelValue(\.active, with: newValue) }
    }
    /// An action ran since the last state read.
    public var needsSettle: Bool {
        get { state.withLock { $0.needsSettle } }
        set { state.replaceModelValue(\.needsSettle, with: newValue) }
    }
    public var revisions: Revisions? {
        get { state.withLock { $0.revisions } }
        set { state.replaceModelValue(\.revisions, with: newValue) }
    }
    /// The last screenshot, for x and y arguments.
    public var shot: Shot? {
        get { state.withLock { $0.shot } }
        set { state.replaceModelValue(\.shot, with: newValue) }
    }
    /// An action ran in a browser since its page was checked against the blocked
    /// list: the page may be another one now.
    public var pageUnchecked: Bool {
        get { state.withLock { $0.pageUnchecked } }
        set { state.replaceModelValue(\.pageUnchecked, with: newValue) }
    }
    /// Person used the app, or client went away. Asked before every posted event,
    /// and inside a held click or key so that the hold ends early.
    /// Snapshot the closure under the state lock; always invoke it after unlocking.
    public var cancel: @Sendable () -> Bool {
        get { state.withLock { $0.cancel } }
        set { state.replaceModelValue(\.cancel, with: newValue) }
    }
    /// The running app switched on at the first read; switch the same one off at
    /// turn end (tree.enable, windows.watch, revisions.watch).
    public var watching: AppTarget? {
        get { state.withLock { $0.watching } }
        set { state.replaceModelValue(\.watching, with: newValue) }
    }

    public init(agent: AgentSession, target: AppTarget) {
        state = OSAllocatedUnfairLock(initialState: State(agent: agent, target: target))
    }
}
