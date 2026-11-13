import ComputerUseCore
import Darwin
import Foundation
import os

/// libproc identity includes birth time so a recycled pid cannot inherit a session.
public struct ProcessIdentity: Equatable, Hashable, Sendable {
    public let pid: pid_t
    public let parent: pid_t
    public let path: String
    public let started: TimeInterval

    public init(pid: pid_t, parent: pid_t, path: String, started: TimeInterval) {
        self.pid = pid
        self.parent = parent
        self.path = path
        self.started = started
    }

    public static func lookup(_ pid: pid_t) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var path = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        _ = proc_pidpath(pid, &path, UInt32(path.count))
        let name = path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        let short = withUnsafeBytes(of: info.pbi_name) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return ProcessIdentity(
            pid: pid, parent: pid_t(info.pbi_ppid), path: name.isEmpty ? short : name,
            started: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }
}

/// Session identity and turn marks for the socket server. App/UI sessions are left
/// to the integration executor; this registry does not depend on Core/Session.swift.
public final class Sessions: Sendable {
    /// May run concurrently and reenter the registry. Captures must own their
    /// synchronization; no provider call runs under the registry lock.
    public typealias ProcessProvider = @Sendable (pid_t) -> ProcessIdentity?
    public static let wrappers: Set<String> = [
        "sh", "bash", "zsh", "dash", "fish", "env", "time", "timeout", "nice", "nohup", "uv", "xargs", "sudo",
        "sandbox-exec",
    ]
    private struct Entry: Sendable {
        let agent: AgentSession
        let host: ProcessIdentity?
        let revision: UInt64
    }
    private struct Shell: Sendable {
        let shell: ProcessIdentity
        let host: ProcessIdentity
        let revision: UInt64
    }
    private struct State: Sendable {
        var revision: UInt64 = 0
        var lookups: [UInt64: Int] = [:]
        // Missing keys need their own retirement revisions to reject ABA without
        // invalidating unrelated callers. Retain only the active epoch window;
        // a stalled oldest provider can extend that window until it returns.
        var retiredAgents: [String: UInt64] = [:]
        var retiredShells: [String: UInt64] = [:]
        var agents: [String: Entry] = [:]
        var shells: [String: Shell] = [:]
        var stopped: Set<String> = []

        mutating func finishLookup(at revision: UInt64) {
            if lookups[revision] == 1 { lookups.removeValue(forKey: revision) }
            else { lookups[revision, default: 0] -= 1 }
            pruneRetirements()
        }
        mutating func pruneRetirements() {
            guard let oldest = lookups.keys.min() else {
                retiredAgents.removeAll()
                retiredShells.removeAll()
                return
            }
            retiredAgents = retiredAgents.filter { $0.value > oldest }
            retiredShells = retiredShells.filter { $0.value > oldest }
        }
    }
    private let process: ProcessProvider
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(process: @escaping ProcessProvider = { ProcessIdentity.lookup($0) }) { self.process = process }

    public func ancestry(of pid: pid_t) -> [ProcessIdentity] {
        var chain: [ProcessIdentity] = []
        var seen: Set<pid_t> = [pid]
        var current = process(pid)
        while let record = current, record.parent > 0, !seen.contains(record.parent) {
            seen.insert(record.parent)
            current = process(record.parent)
            if let current { chain.append(current) }
        }
        return chain
    }

    /// Advisory product scoping, not a sandbox/security boundary. The sole dev
    /// override is the hidden <state>/allow-any-caller file, checked by the server.
    public func callerAllowed(_ pid: pid_t) -> Bool {
        ancestry(of: pid).contains { ($0.path as NSString).lastPathComponent == "term-llm" }
    }

    private func isWrapper(_ record: ProcessIdentity) -> Bool {
        Self.wrappers.contains(String((record.path as NSString).lastPathComponent.drop(while: { $0 == "-" })))
    }
    private func runs(_ record: ProcessIdentity) -> Bool { process(record.pid)?.started == record.started }
    private func key(_ record: ProcessIdentity) -> String { "\(record.pid):\(record.started)" }

    // Internal ownership diagnostics for pure epoch-retention regression tests.
    var lookupOwnershipCounts: (active: Int, retiredAgents: Int, retiredShells: Int) {
        state.withLock { ($0.lookups.values.reduce(0, +), $0.retiredAgents.count, $0.retiredShells.count) }
    }

    public func agent(peerPID: pid_t, env: [String: String]) -> AgentSession {
        let snapshot = state.withLock { state in
            state.lookups[state.revision, default: 0] += 1
            return (revision: state.revision, shells: state.shells)
        }
        defer { state.withLock { $0.finishLookup(at: snapshot.revision) } }
        let parents = ancestry(of: peerPID)
        let override = [env["TERM_LLM_SESSION_ID"], env["TERM_LLM_COMPUTER_SESSION"]].compactMap { $0 }.first {
            !$0.isEmpty
        }
        let host = override == nil ? parents.first { !isWrapper($0) } : nil
        let wrappers = override == nil ? Array(parents.prefix(while: isWrapper)) : []
        var orphan: Shell?
        for wrapper in wrappers {
            if let previous = snapshot.shells[key(wrapper)], previous.host != host, !runs(previous.host) {
                orphan = previous
                break
            }
        }
        let sessionKey = override ?? host.map(key) ?? "no-agent"
        var bundles: Set<String> = []
        for parent in parents {
            let parts = parent.path.split(separator: "/", omittingEmptySubsequences: false)
            for i in parts.indices where parts[i].hasSuffix(".app") && i < parts.count - 1 {
                bundles.insert(parts[...i].joined(separator: "/"))
            }
        }
        let hosts = bundles, sampledOrphan = orphan
        return state.withLock { state in
            // Liveness of the former host is useful only while this wrapper still
            // belongs to that association. A provider may have remapped it while
            // sampling; in that case use the current registration below.
            if let orphan = sampledOrphan, state.shells[key(orphan.shell)]?.revision == orphan.revision {
                return AgentSession(key: key(orphan.host), exited: true)
            }
            // A newer entry or wrapper revision supersedes this sample, even for
            // the same explicit ID or process identity. Do not retry: a reentrant
            // provider could otherwise invalidate every attempt.
            let shellsUnchanged = wrappers.allSatisfy {
                let current = state.shells[key($0)]
                return current?.revision == snapshot.shells[key($0)]?.revision
                    && (current != nil || (state.retiredShells[key($0)] ?? 0) <= snapshot.revision)
            }
            let found = state.agents[sessionKey]
            let entryUnchanged = found.map { $0.revision <= snapshot.revision }
                ?? ((state.retiredAgents[sessionKey] ?? 0) <= snapshot.revision)
            guard shellsUnchanged, entryUnchanged else {
                // Only a changed wrapper association can supersede the sampled
                // host. If just its entry changed, return that host's registration.
                // Never publish this stale call's environment or associations.
                if !shellsUnchanged, let first = wrappers.first, let current = state.shells[key(first)],
                   wrappers.allSatisfy({ state.shells[key($0)]?.host == current.host }) {
                    let currentKey = key(current.host)
                    return state.agents[currentKey]?.agent ?? AgentSession(key: currentKey, exited: true)
                }
                if let found { return found.agent }
                return AgentSession(key: sessionKey, exited: true)
            }
            state.revision += 1
            for wrapper in wrappers {
                if let host {
                    state.shells[key(wrapper)] = Shell(shell: wrapper, host: host, revision: state.revision)
                }
            }
            let agent = found?.agent ?? AgentSession(key: sessionKey, hosts: hosts)
            state.agents[sessionKey] = Entry(agent: agent, host: found == nil ? host : found?.host, revision: state.revision)
            agent.env = env
            return agent
        }
    }

    public func hostGone(_ agent: AgentSession) -> Bool {
        if agent.exited { return true }
        let entry = state.withLock { $0.agents[agent.key] }
        guard let entry, entry.agent === agent, let host = entry.host else { return agent.exited }
        let gone = !runs(host)
        return state.withLock { state in
            // A refreshed/replaced registration supersedes this liveness sample.
            agent.exited || (state.agents[agent.key]?.revision == entry.revision && gone)
        }
    }
    /// Drop dead process-keyed sessions, including Stop marks. Explicit IDs survive.
    @discardableResult public func reap() -> [AgentSession] {
        let snapshot = state.withLock { ($0.agents, $0.shells) }
        let dead = snapshot.0.filter { $0.value.host.map { !runs($0) } == true }
        let shells = snapshot.1.filter { !runs($0.value.shell) }
        return state.withLock { state in
            var removed: [AgentSession] = []
            for (key, shell) in shells where state.shells[key]?.revision == shell.revision {
                state.shells.removeValue(forKey: key)
                state.revision += 1
                state.retiredShells[key] = state.revision
            }
            for (key, entry) in dead where state.agents[key]?.revision == entry.revision {
                state.agents.removeValue(forKey: key)
                state.stopped.remove(key)
                entry.agent.exited = true
                removed.append(entry.agent)
                state.revision += 1
                state.retiredAgents[key] = state.revision
            }
            state.pruneRetirements()
            return removed
        }
    }
    public func turnStarted(_ agent: AgentSession) {
        state.withLock { state in
            agent.withState {
                agent.ended = false
                agent.signalsTurns = true
                agent.denied.removeAll()
                agent.instructed.removeAll()
            }
            state.stopped.remove(agent.key)
        }
    }
    /// Upstream let_go: only a cancelling end marks a signalled turn ended.
    public func letGo(_ agent: AgentSession, cancel: Bool) {
        state.withLock { _ in
            agent.withState { if cancel { agent.cancels += 1; agent.ended = agent.signalsTurns } }
        }
    }
    public func turnEnded(_ agent: AgentSession, cancel: Bool) {
        state.withLock { _ in
            agent.withState {
                agent.ended = true
                if cancel { agent.cancels += 1 }
            }
        }
    }
    public func cancellationGeneration(_ agent: AgentSession) -> Int { agent.cancels }
    public func isStopped(_ agent: AgentSession) -> Bool { state.withLock { $0.stopped.contains(agent.key) } }
    public func hasEnded(_ agent: AgentSession) -> Bool { agent.ended }
    public func stop(_ keys: Set<String>) {
        state.withLock { state in
            for key in keys {
                state.stopped.insert(key)
                if let agent = state.agents[key]?.agent { agent.withState { agent.cancels += 1 } }
            }
        }
    }
}
