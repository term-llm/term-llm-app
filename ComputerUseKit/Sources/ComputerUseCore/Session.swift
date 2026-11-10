import Foundation

/// One app as one agent sees it. Lives in the helper between calls.
public final class AppSession {
    public var agent: AgentSession
    // These two fields are also snapshotted by panel ownership and turn reaping
    // before taking an app FIFO; their values must not race a process restart.
    private let contextLock = NSLock()
    private var currentTarget: AppTarget
    public var target: AppTarget {
        get { contextLock.lock(); defer { contextLock.unlock() }; return currentTarget }
        set { contextLock.lock(); defer { contextLock.unlock() }; currentTarget = newValue }
    }
    /// A state read succeeded since the session or the turn began.
    public var active = false
    /// An action ran since the last state read.
    public var needsSettle = false
    public var revisions: Revisions?
    /// The last screenshot, for x and y arguments.
    public var shot: Shot?
    /// An action ran in a browser since its page was checked against the blocked
    /// list: the page may be another one now.
    public var pageUnchecked = false
    /// Person used the app, or client went away. Asked before every posted event,
    /// and inside a held click or key so that the hold ends early.
    public var cancel: () -> Bool = { false }
    /// The running app switched on at the first read; switch the same one off at
    /// turn end (tree.enable, windows.watch, revisions.watch).
    private var watchedTarget: AppTarget?
    public var watching: AppTarget? {
        get { contextLock.lock(); defer { contextLock.unlock() }; return watchedTarget }
        set { contextLock.lock(); defer { contextLock.unlock() }; watchedTarget = newValue }
    }

    public init(agent: AgentSession, target: AppTarget) {
        self.agent = agent
        self.currentTarget = target
    }
}
