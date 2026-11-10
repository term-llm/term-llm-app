import ComputerUseCore
import Foundation

/// The person says which apps the agent may drive. A yes holds for one agent
/// session or for good. A no holds until the turn ends; a host without turn
/// signals refuses one call. A timed-out call leaves its question on screen.
public final class Approvals {
    public static let deny = "Deny", session = "Allow for this session", always = "Always allow"
    public static let poll: TimeInterval = 0.25, giveUp: TimeInterval = 10
    private struct Key: Hashable, Sendable {
        let agent: String?
        let bundle: String
    }
    private let lock = NSRecursiveLock()
    private var sessions: Set<Key> = []
    private var asking: [Key: String] = [:]
    private let store: ApprovalStore
    private let show: (Ask) -> Bool
    private let withdraw: (String) -> Void
    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) -> Void
    private let alive: (String) -> Bool
    public init(
        store: ApprovalStore = ApprovalStore(),
        ask: @escaping (Ask) -> Bool = { Presence.shared.ask($0) },
        withdraw: @escaping (String) -> Void = { _ = Presence.shared.withdraw(title: $0) },
        now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
        sleep: @escaping (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
        alive: @escaping (String) -> Bool = Approvals.namedSessionAlive
    ) {
        self.store = store
        self.show = ask
        self.withdraw = withdraw
        self.now = now
        self.sleep = sleep
        self.alive = alive
    }
    /// HarnessExecutor supplies process lookup (pid AND start time).
    /// Without it, numeric keys fail closed across helper restarts. Named term-llm
    /// session IDs cannot be asked about a process and remain valid as upstream.
    public static func namedSessionAlive(_ key: String) -> Bool {
        guard let first = key.split(separator: ":", maxSplits: 1).first else { return true }
        return !first.allSatisfy(\.isNumber)
    }
    public func stored() -> (always: [String: String], session: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (store.always(), Array(Set(sessions.map(\.bundle))).sorted())
    }
    /// Human-facing/library API only. Never route from agent argv or the socket.
    /// The main app edits ApprovalStore directly; panel answers are session-scoped.
    /// A direct grant lasts for this helper's life, or persists if always.
    public func approve(bundleID: String, always: Bool) throws {
        try record(bundleID: bundleID, always: always, agent: nil)
    }
    private func record(bundleID: String, always: Bool, agent: String?) throws {
        lock.lock()
        defer { lock.unlock() }
        sessions.insert(Key(agent: agent, bundle: bundleID))
        let settled = asking.filter {
            $0.key.bundle == bundleID && (agent == nil || $0.key.agent == agent)
        }
        for (key, title) in settled {
            asking.removeValue(forKey: key)
            withdraw(title)
        }
        if let agent, agent != "no-agent" {
            try? store.saveSession(agent: agent, bundleID: bundleID, alive: alive)
        }
        if always {
            do { try store.save(bundleID: bundleID) } catch {
                throw Errors.make("approval_not_saved", ["bundle_id": bundleID])
            }
        }
    }
    public func approved(agent: AgentSession, bundleID: String, policy: PolicyDecision) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessions.contains(Key(agent: agent.key, bundle: bundleID))
            || sessions.contains(Key(agent: nil, bundle: bundleID))
            || store.sessions(alive: alive).contains(.init(agent: agent.key, bundleID: bundleID))
            || (policy.allowPersistent && store.always()[bundleID] != nil)
    }
    public func ensure(
        agent: AgentSession, target: AppTarget, policy: PolicyDecision, deadline: TimeInterval,
        abandoned: () -> Bool = { false }
    ) throws {
        if policy.decision != .allowed {
            throw Errors.make(
                policy.decision == .denied ? "denied_by_policy" : "forbidden",
                ["bundle_id": target.bundleID])
        }
        if !policy.ask { return }
        let name = Policy.displayName(target)
        let key = Key(agent: agent.key, bundle: target.bundleID)
        while !approved(agent: agent, bundleID: target.bundleID, policy: policy) {
            lock.lock()
            let denied = agent.withState {
                let denied = agent.denied.contains(target.path)
                if denied && !agent.signalsTurns { agent.denied.remove(target.path) }
                return denied
            }
            if denied {
                lock.unlock()
                throw Errors.make("not_approved", ["display_name": name])
            }
            let needsQuestion = asking[key] == nil
            let title = "May \(product) control \"\(name)\"?"
            if needsQuestion { asking[key] = title }
            // Keep the enqueue ordered with control-socket approval/withdrawal.
            // The show seam only hands work over; it must never wait for UI.
            if needsQuestion {
                let lasting = policy.allowPersistent && !target.bundleID.hasPrefix("#pid:")
                let choices = [Self.deny, Self.session] + (lasting ? [Self.always] : [])
                let question = Ask(title: title, subtitle: policy.warning, choices: choices) {
                    [weak self] choice in
                    guard let self else { return }
                    self.lock.lock()
                    defer { self.lock.unlock() }
                    self.asking.removeValue(forKey: key)
                    if choice != Self.session && choice != Self.always {
                        agent.denied.insert(target.path)
                        return
                    }
                    // The disk refused: the yes still holds for now.
                    try? self.record(
                        bundleID: target.bundleID, always: choice == Self.always, agent: agent.key)
                }
                if !show(question) {
                    asking.removeValue(forKey: key)
                    lock.unlock()
                    throw Errors.make("approval_unavailable", ["display_name": name])
                }
            }
            lock.unlock()
            if now() >= deadline - Self.giveUp {
                throw Errors.make("approval_pending", ["display_name": name])
            }
            if abandoned() { throw Errors.make("request_timed_out") }
            sleep(Self.poll)
        }
    }
    /// HarnessExecutor calls this at turn boundaries. AgentSession.withState
    /// synchronizes denial changes with lifecycle workers and panel callbacks.
    public func clearDenials(agent: AgentSession) {
        lock.lock()
        defer { lock.unlock() }
        agent.withState { agent.denied.removeAll() }
    }
}
