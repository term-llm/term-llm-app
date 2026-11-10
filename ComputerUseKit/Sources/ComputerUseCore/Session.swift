import Foundation

/// One app as one agent sees it. Lives in the helper between calls.
public final class AppSession {
    public var agent: AgentSession
    public var target: AppTarget
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
    public var watching: AppTarget?

    public init(agent: AgentSession, target: AppTarget) {
        self.agent = agent
        self.target = target
    }
}
