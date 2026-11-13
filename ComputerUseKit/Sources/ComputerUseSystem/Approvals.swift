import ComputerUseCore
import Foundation
import os

/// The person says which apps the agent may drive. A yes holds for one agent
/// session or for good. A no holds until the turn ends; a host without turn
/// signals refuses one call. A timed-out call leaves its question on screen.
/// Dependencies are immutable and may be called concurrently. State transitions
/// reserve ordered UI effects; no callback or filesystem operation holds the state
/// lock. Ask/withdraw hooks must only enqueue UI work, never wait for the UI.
public final class Approvals: Sendable {
    public static let deny = "Deny", session = "Allow for this session", always = "Always allow"
    public static let poll: TimeInterval = 0.25, giveUp: TimeInterval = 10
    private struct Key: Hashable, Sendable {
        let agent: String?
        let bundle: String
    }
    private enum Phase: Sendable { case queued, showing, shown, unavailable }
    private struct Question: Sendable {
        let id: UUID
        let generation: UUID
        let cancels: Int
        let ask: Ask
        var phase: Phase = .queued
    }
    private enum Effect: Sendable {
        case show(Key, UUID)
        case withdraw(String)
    }
    private struct Generation: Sendable {
        let id = UUID()
        var waiters = 0
    }
    private struct State: Sendable {
        var sessions: Set<Key> = []
        var asking: [Key: Question] = [:]
        var generations: [String: Generation] = [:]
        var effects: [Effect] = []
        var draining = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    // An internal ownership snapshot for pure lifetime/retirement tests.
    var generationCount: Int { state.withLock { $0.generations.count } }
    private static func pruneGeneration(_ state: inout State, agent: String) {
        if state.generations[agent]?.waiters == 0,
            !state.asking.keys.contains(where: { $0.agent == agent }) {
            state.generations.removeValue(forKey: agent)
        }
    }
    private static func retire(_ state: inout State, keys: Set<String>) {
        for key in keys { state.generations.removeValue(forKey: key) }
        let stale = state.asking.filter { $0.key.agent.map(keys.contains) == true }
        for (key, question) in stale {
            state.asking.removeValue(forKey: key)
            state.effects.append(.withdraw(question.ask.title))
        }
    }
    // A separate commit gate protects same-instance filesystem read/modify/write,
    // never approval state. No injected callback runs inside it.
    // Internal visibility lets fake-only tests pause commits deterministically.
    struct PersistenceState: Sendable { var sessionRevision = UUID() }
    let persistence = OSAllocatedUnfairLock(initialState: PersistenceState())
    private let store: ApprovalStore
    private let show: @Sendable (Ask) -> Bool
    private let withdraw: @Sendable (String) -> Void
    private let now: @Sendable () -> TimeInterval
    private let sleep: @Sendable (TimeInterval) -> Void
    private let alive: @Sendable (String) -> Bool
    public init(
        store: ApprovalStore = ApprovalStore(),
        ask: @escaping @Sendable (Ask) -> Bool = { Presence.shared.ask($0) },
        withdraw: @escaping @Sendable (String) -> Void = { _ = Presence.shared.withdraw(title: $0) },
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
        sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        alive: @escaping @Sendable (String) -> Bool = { Approvals.namedSessionAlive($0) }
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
        let sessions = state.withLock { Array(Set($0.sessions.map(\.bundle))).sorted() }
        return (store.always(), sessions)
    }
    /// Human-facing/library API only. Never route from agent argv or the socket.
    /// The main app edits ApprovalStore directly; panel answers are session-scoped.
    /// A direct grant lasts for this helper's life, or persists if always.
    public func approve(bundleID: String, always: Bool) throws {
        state.withLock { state in
            state.sessions.insert(Key(agent: nil, bundle: bundleID))
            let settled = state.asking.filter { $0.key.bundle == bundleID }
            for (key, question) in settled {
                state.asking.removeValue(forKey: key)
                state.effects.append(.withdraw(question.ask.title))
                if let agent = key.agent { Self.pruneGeneration(&state, agent: agent) }
            }
        }
        drain()
        try persist(bundleID: bundleID, always: always, agent: nil)
    }
    private func persist(bundleID: String, always: Bool, agent: String?) throws {
        if let agent, agent != "no-agent" {
            try? persistSession(agent: agent, bundleID: bundleID)
        }
        if always {
            do {
                try persistence.withLock { _ in try store.save(bundleID: bundleID) }
            } catch {
                throw Errors.make("approval_not_saved", ["bundle_id": bundleID])
            }
        }
    }
    private func persistSession(agent: String, bundleID: String) throws {
        while true {
            let revision = persistence.withLock { $0.sessionRevision }
            // Liveness can block or reenter Approvals, including another answer.
            // Probe outside both locks. A concurrent/reentrant session commit
            // invalidates this sample, so it cannot overwrite that newer grant.
            let liveAgents = Set(store.sessions(alive: alive).map(\.agent))
            let saved = try persistence.withLock { state in
                guard state.sessionRevision == revision else { return false }
                // This callback uses only the local immutable sample, never an
                // injected dependency. All same-instance commits are serialized.
                try store.saveSession(
                    agent: agent, bundleID: bundleID, alive: { liveAgents.contains($0) })
                state.sessionRevision = UUID()
                return true
            }
            if saved { return }
        }
    }
    private static func locallyApproved(_ state: State, key: Key) -> Bool {
        state.sessions.contains(key) || state.sessions.contains(Key(agent: nil, bundle: key.bundle))
    }
    public func approved(agent: AgentSession, bundleID: String, policy: PolicyDecision) -> Bool {
        let key = Key(agent: agent.key, bundle: bundleID)
        if state.withLock({ Self.locallyApproved($0, key: key) }) { return true }
        // ApprovalStore is memory-Sendable, not a filesystem transaction. Reads
        // observe external edits; concurrent read/modify/write can still lose updates.
        return store.sessions(alive: alive).contains(.init(agent: agent.key, bundleID: bundleID))
            || (policy.allowPersistent && store.always()[bundleID] != nil)
            || state.withLock { Self.locallyApproved($0, key: key) }
    }
    private func answer(
        _ choice: String, key: Key, id: UUID, generation: UUID, cancels: Int,
        agent: AgentSession, path: String, lasting: Bool
    ) {
        let granted = state.withLock { state in
            agent.withState {
                guard let question = state.asking[key], question.id == id,
                    question.phase != .unavailable else { return false }
                // The panel already consumed this exact question. Even a stale
                // answer must remove its matching entry so title-wide restoration
                // cannot put a dead prompt back on screen. Never consume a newer ID.
                let current = state.generations[agent.key]?.id == generation
                    && agent.cancels == cancels && !agent.ended && !agent.exited
                state.asking.removeValue(forKey: key)
                Self.pruneGeneration(&state, agent: agent.key)
                guard current else { return false }
                guard choice == Self.session || (lasting && choice == Self.always) else {
                    agent.denied.insert(path)
                    return false
                }
                state.sessions.insert(key)
                return true
            }
        }
        // A failed persistent write still grants this session, as before.
        if granted { try? persist(bundleID: key.bundle, always: choice == Self.always, agent: agent.key) }
    }
    /// One drainer preserves enqueue/withdraw order without holding the state
    /// lock over a seam. Reentrant calls append work and return, never self-wait.
    /// Other workers can keep checking grants/cancellation while a seam is busy.
    private func drain() {
        let claimed = state.withLock { state in
            guard !state.draining else { return false }
            state.draining = true
            return true
        }
        guard claimed else { return }
        while let effect = state.withLock({ state -> Effect? in
            guard !state.effects.isEmpty else { state.draining = false; return nil }
            return state.effects.removeFirst()
        }) {
            switch effect {
            case .show(let key, let id):
                let ask = state.withLock { state -> Ask? in
                    guard var question = state.asking[key], question.id == id,
                        question.phase == .queued else { return nil }
                    question.phase = .showing
                    state.asking[key] = question
                    return question.ask
                }
                guard let ask else { continue }
                let available = show(ask)
                state.withLock { state in
                    guard var question = state.asking[key], question.id == id else { return }
                    question.phase = available ? .shown : .unavailable
                    state.asking[key] = question
                }
            case .withdraw(let title):
                withdraw(title)
                // The UI seam withdraws by title, not question identity. Restore
                // unrelated agents' questions removed by that title-wide operation.
                state.withLock { state in
                    for (key, var question) in state.asking
                    where question.ask.title == title && question.phase == .shown {
                        question.phase = .queued
                        state.asking[key] = question
                        state.effects.append(.show(key, question.id))
                    }
                }
            }
        }
    }
    private enum Step { case wait, granted, denied, unavailable, cancelled }
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
        let generation = state.withLock { state in
            var generation = state.generations[agent.key] ?? Generation()
            generation.waiters += 1
            state.generations[agent.key] = generation
            return generation.id
        }
        defer {
            state.withLock { state in
                guard var current = state.generations[agent.key], current.id == generation else { return }
                current.waiters -= 1
                state.generations[agent.key] = current
                Self.pruneGeneration(&state, agent: agent.key)
            }
        }
        let cancels = agent.cancels
        while true {
            // Disk and process-lookup callbacks must run outside our state lock.
            let current = state.withLock { state in
                agent.withState {
                    state.generations[agent.key]?.id == generation
                        && agent.cancels == cancels && !agent.ended && !agent.exited
                }
            }
            let allowed = current && approved(agent: agent, bundleID: target.bundleID, policy: policy)
            let step = state.withLock { state -> Step in
                agent.withState {
                    guard state.generations[agent.key]?.id == generation,
                        agent.cancels == cancels, !agent.ended, !agent.exited
                    else {
                        // A cancelled waiter owns only its old generation and
                        // cancel snapshot, never a replacement question for this key.
                        if let question = state.asking[key], question.generation == generation,
                            question.cancels == cancels {
                            state.asking.removeValue(forKey: key)
                            state.effects.append(.withdraw(question.ask.title))
                        }
                        return .cancelled
                    }
                    if allowed || Self.locallyApproved(state, key: key) { return .granted }
                    if agent.denied.contains(target.path) {
                        if !agent.signalsTurns { agent.denied.remove(target.path) }
                        return .denied
                    }
                    if let question = state.asking[key] {
                        if question.generation != generation || question.cancels != cancels {
                            state.asking.removeValue(forKey: key)
                            state.effects.append(.withdraw(question.ask.title))
                        } else {
                            if question.phase == .unavailable {
                                state.asking.removeValue(forKey: key)
                                return .unavailable
                            }
                            return .wait
                        }
                    }
                    let id = UUID()
                    let lasting = policy.allowPersistent && !target.bundleID.hasPrefix("#pid:")
                    let question = Ask(
                        title: "May \(product) control \"\(name)\"?", subtitle: policy.warning,
                        choices: [Self.deny, Self.session] + (lasting ? [Self.always] : [])
                    ) { [weak self] choice in
                        self?.answer(
                            choice, key: key, id: id, generation: generation, cancels: cancels,
                            agent: agent, path: target.path, lasting: lasting)
                    }
                    state.asking[key] = Question(
                        id: id, generation: generation, cancels: cancels, ask: question)
                    state.effects.append(.show(key, id))
                    return .wait
                }
            }
            switch step {
            case .granted: return
            case .denied: throw Errors.make("not_approved", ["display_name": name])
            case .unavailable: throw Errors.make("approval_unavailable", ["display_name": name])
            case .cancelled:
                drain()
                throw Errors.make("request_timed_out")
            case .wait: break
            }
            drain()
            if state.withLock({ $0.generations[agent.key]?.id != generation })
                || agent.withState({ agent.cancels != cancels || agent.ended || agent.exited }) {
                continue  // Centralized matching-question cleanup before throwing.
            }
            // A synchronous answer or unavailable panel must be observed before
            // deadline checks, without sleeping or asking a second question.
            let settled = state.withLock { state in
                Self.locallyApproved(state, key: key)
                    || state.asking[key]?.phase == .unavailable
            } || agent.denied.contains(target.path)
            if settled { continue }
            if now() >= deadline - Self.giveUp {
                throw Errors.make("approval_pending", ["display_name": name])
            }
            if abandoned() { throw Errors.make("request_timed_out") }
            sleep(Self.poll)
        }
    }
    /// A normal, non-cancelling turn end clears denials but leaves a live or
    /// timed-out approval question answerable, matching the upstream lifecycle.
    public func clearDenials(agent: AgentSession) {
        agent.withState { agent.denied.removeAll() }
    }
    /// A new turn invalidates the old turn's questions, not its session grants.
    /// Do not allocate a generation for an agent that has never asked/waited.
    public func beginTurn(agent: AgentSession) {
        state.withLock { state in
            agent.withState { agent.denied.removeAll() }
            Self.retire(&state, keys: [agent.key])
        }
        drain()
    }
    /// Stop/cancelling turn end/agent exit also retire questions whose original
    /// request already returned approval_pending and has no remaining waiter.
    /// Removing the generation retires old waiters without retaining exited IDs.
    public func cancel(keys: Set<String>) {
        state.withLock { Self.retire(&$0, keys: keys) }
        drain()
    }
}
