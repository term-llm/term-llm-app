import ComputerUseCore
import Darwin
import Foundation

/// libproc identity includes birth time so a recycled pid cannot inherit a session.
public struct ProcessIdentity: Equatable, Hashable {
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
        let name = String(cString: path)
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
public final class Sessions {
    public typealias ProcessProvider = (pid_t) -> ProcessIdentity?
    public static let wrappers: Set<String> = [
        "sh", "bash", "zsh", "dash", "fish", "env", "time", "timeout", "nice", "nohup", "uv", "xargs", "sudo",
        "sandbox-exec",
    ]
    private let process: ProcessProvider
    private let lock = NSRecursiveLock()
    private var agents: [String: AgentSession] = [:]
    private var born: [String: ProcessIdentity] = [:]
    private var shells: [String: (shell: ProcessIdentity, host: ProcessIdentity)] = [:]
    private var stopped: Set<String> = []

    public init(process: @escaping ProcessProvider = ProcessIdentity.lookup) { self.process = process }

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

    public func agent(peerPID: pid_t, env: [String: String]) -> AgentSession {
        lock.lock()
        defer { lock.unlock() }
        let parents = ancestry(of: peerPID)
        let override = [env["TERM_LLM_SESSION_ID"], env["TERM_LLM_COMPUTER_SESSION"]].compactMap { $0 }.first {
            !$0.isEmpty
        }
        let host = override == nil ? parents.first { !isWrapper($0) } : nil
        let wrappers = override == nil ? Array(parents.prefix(while: isWrapper)) : []
        for wrapper in wrappers {
            if let previous = shells[key(wrapper)]?.host, previous != host, !runs(previous) {
                return AgentSession(key: key(previous), exited: true)
            }
        }
        if let host { for wrapper in wrappers { shells[key(wrapper)] = (wrapper, host) } }
        let sessionKey = override ?? host.map(key) ?? "no-agent"
        let agent: AgentSession
        if let found = agents[sessionKey] {
            agent = found
        } else {
            var bundles: Set<String> = []
            for parent in parents {
                let parts = parent.path.split(separator: "/", omittingEmptySubsequences: false)
                for i in parts.indices where parts[i].hasSuffix(".app") && i < parts.count - 1 {
                    bundles.insert(parts[...i].joined(separator: "/"))
                }
            }
            agent = AgentSession(key: sessionKey, hosts: bundles)
            agents[sessionKey] = agent
            if let host { born[sessionKey] = host }
        }
        agent.env = env
        return agent
    }

    public func hostGone(_ agent: AgentSession) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return agent.exited || born[agent.key].map { !runs($0) } == true
    }
    /// Drop dead process-keyed sessions, including Stop marks. Explicit IDs survive.
    @discardableResult public func reap() -> [AgentSession] {
        lock.lock()
        defer { lock.unlock() }
        let dead = born.filter { !runs($0.value) }.map(\.key)
        shells = shells.filter { runs($0.value.shell) }
        return dead.compactMap { key in
            born.removeValue(forKey: key)
            stopped.remove(key)
            let agent = agents.removeValue(forKey: key)
            agent?.exited = true
            return agent
        }
    }
    public func turnStarted(_ agent: AgentSession) {
        lock.lock()
        defer { lock.unlock() }
        agent.withState {
            agent.ended = false
            agent.signalsTurns = true
            agent.denied.removeAll()
            agent.instructed.removeAll()
        }
        stopped.remove(agent.key)
    }
    /// Upstream let_go: only a cancelling end marks a signalled turn ended.
    public func letGo(_ agent: AgentSession, cancel: Bool) {
        lock.lock(); defer { lock.unlock() }
        agent.withState { if cancel { agent.cancels += 1; agent.ended = agent.signalsTurns } }
    }
    public func turnEnded(_ agent: AgentSession, cancel: Bool) {
        lock.lock()
        defer { lock.unlock() }
        agent.ended = true
        if cancel { agent.cancels += 1 }
    }
    public func cancellationGeneration(_ agent: AgentSession) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return agent.cancels
    }
    public func isStopped(_ agent: AgentSession) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped.contains(agent.key)
    }
    public func hasEnded(_ agent: AgentSession) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return agent.ended
    }
    public func stop(_ keys: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        for key in keys {
            stopped.insert(key)
            agents[key]?.cancels += 1
        }
    }
}
