import ComputerUseCore
import ComputerUseSystem
import CoreFoundation
import Darwin
import Foundation
import os

public enum ComputerUseHelperInfo { public static let version = ComputerUseVersion.current }

/// Pluggable permission hooks keep the shell and main app free of TCC requests.
/// `allow` runs on a worker: use MainThread for any permission UI it needs.
public struct HelperConfiguration: Sendable {
    public var environment: [String: String]
    public var grants: @Sendable () -> [String: Bool]
    public var onStarted: @Sendable () -> Void = {}
    public var onMaintenance: @Sendable () -> Void = {}
    /// Asked every maintenance tick while no call runs: true makes this helper exit
    /// so its owning app starts a fresh one (a grant macOS reads only at launch).
    public var wantsRelaunch: @Sendable () -> Bool = { false }
    /// Running count is aggregated here; ActivityBanner owns the same 3 s grace.
    /// Ordered outside bookkeeping locks. May reenter status/Stop; enqueue shutdown
    /// rather than synchronously waiting for calls or UI work.
    public var onWorking: @Sendable (Bool) -> Void = { _ in }
    /// Installs a Sendable, enqueue-only person/host Stop hook. The callback
    /// supplied by HelperMain never synchronously joins server or UI workers.
    public var installStop: @Sendable (@escaping @Sendable () -> Void) -> Void = { _ in }
    public var allow: @Sendable (String) throws -> Void
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        grants: @escaping @Sendable () -> [String: Bool] = { [:] },
        allow: @escaping @Sendable (String) throws -> Void = { _ in
            throw Errors.serverError("Permission requests are not implemented yet in this Computer Use shell.")
        }
    ) {
        self.environment = environment
        self.grants = grants
        self.allow = allow
    }
}

/// One helper per socket. `start`/`stop` also work without AppKit for socket tests.
public final class HelperServer: Sendable {
    public let sessions: Sessions
    /// A value-builder snapshot: later mutations of the caller's builder cannot
    /// change the dependency graph used by workers.
    public let configuration: HelperConfiguration
    private let executor: ToolExecutor
    private let condition = NSCondition()
    private let workers = DispatchGroup()
    // Covers startup from enrollment through either rollback or accept-loop exit.
    private let accepting = DispatchGroup()
    private let startupExecution = NSLock()
    private let persistenceExecution = NSLock()
    private let connectionExecution = NSLock()
    private let awake = DisplayAwake()
    private let log: HelperLog
    private struct State: Sendable {
        var listener: Int32 = -1
        var lockFD: Int32 = -1
        var connections: Set<Int32> = []
        var queues: [String: AppFIFO] = [:]
        var running = 0
        var active: [String: Int] = [:]
        var recentAgents: [String: Date] = [:]
        var lastCall = Date.distantPast
        var stopping = false
        var paused = false
        var pauseGeneration = 0
        var stopGeneration = 0
        var started = false
        var finished = false
        var onShutdown: (@Sendable () -> Void)?
        var workingEffects: [Bool] = []
        var drainingWorking = false
    }
    // Checked storage protects the entire typed graph. The condition coordinates
    // waiters; always take it BEFORE storage, and never wait with storage locked.
    private let storage: OSAllocatedUnfairLock<State>
    private let created = Date()
    private let stateDirectory: URL
    private let socketPath: String
    private let contextKey = "ComputerUseHelper.worker." + UUID().uuidString

    private func withState<T: Sendable>(_ body: @Sendable (inout State) throws -> T) rethrows -> T {
        condition.lock()
        defer { condition.unlock() }
        return try storage.withLock(body)
    }

    /// Replacing or retiring a closure releases its captured graph outside both
    /// locks. Assignments after shutdown are retired, not invoked a second time.
    public var onShutdown: (@Sendable () -> Void)? {
        get { withState { $0.onShutdown } }
        set {
            let previous = withState { state in
                let previous = state.onShutdown
                if !state.finished { state.onShutdown = newValue }
                return previous
            }
            withExtendedLifetime(previous) {}
        }
    }

    public init(
        executor: ToolExecutor = StubToolExecutor(), configuration: HelperConfiguration = HelperConfiguration(),
        sessions: Sessions = Sessions()
    ) {
        self.executor = executor
        self.configuration = configuration
        self.sessions = sessions
        log = HelperLog(environment: configuration.environment)
        stateDirectory = Paths.stateDirectory(env: configuration.environment)
        socketPath = Paths.socketPath(env: configuration.environment)
        storage = OSAllocatedUnfairLock(initialState: State(
            paused: FileManager.default.fileExists(atPath: stateDirectory.appendingPathComponent("paused").path)))
    }
    deinit {
        let fd = storage.withLock { $0.lockFD }
        if fd >= 0 { close(fd) }
    }

    /// Throws EWOULDBLOCK if a helper already owns this socket. Never steals its lock.
    public func start() throws {
        // Concurrent starts are idempotent, but flock/filesystem waits never hold
        // the bookkeeping condition used by Stop and status.
        startupExecution.lock()
        defer { startupExecution.unlock() }
        let begin = try withState { state in
            guard !state.started else { return false }
            guard !state.stopping else { throw WireError.closed }
            accepting.enter()
            return true
        }
        guard begin else { return }
        var handedOff = false
        defer { if !handedOff { accepting.leave() } }
        // Core allocates before validating a socket address, including probes.
        // Reject invalid configuration before any allocation or filesystem work.
        let address = sockaddr_un()
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw WireError.system("socket path too long", ENAMETOOLONG)
        }
        try UnixSocket.makeOwnFolder(stateDirectory.path)
        try UnixSocket.makeOwnFolder((socketPath as NSString).deletingLastPathComponent)
        let lockPath = Paths.lockPath(env: configuration.environment)
        let lockFD = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw WireError.system("open lock", errno) }
        var ownsLock = false
        var listener: Int32 = -1
        defer {
            if !handedOff {
                if listener >= 0 { close(listener); unlink(socketPath) }
                if ownsLock { flock(lockFD, LOCK_UN) }
                close(lockFD)
            }
        }
        var info = stat()
        guard fstat(lockFD, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG else {
            throw WireError.system("lock ownership", EPERM)
        }
        let until = Date().addingTimeInterval(5)
        while flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            if isStopping { throw WireError.closed }
            if let probe = try? UnixSocket.connect(socketPath, timeout: 0.1) {
                close(probe)
                throw WireError.system("helper already running", EWOULDBLOCK)
            }
            if Date() >= until { throw WireError.system("flock", EWOULDBLOCK) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        ownsLock = true
        guard !isStopping else { throw WireError.closed }
        do {
            listener = try UnixSocket.listen(socketPath)
        } catch {
            // Only this error occurs after a successful bind. Core has already
            // closed its fd, but the newly bound path still needs rollback while
            // we own flock. Never unlink on lock, address, socket or bind failure.
            if case WireError.system("listen", _) = error { unlink(socketPath) }
            throw error
        }
        try withState { [listener] state in
            guard !state.stopping else { throw WireError.closed }
            state.listener = listener
            state.lockFD = lockFD
            state.started = true
        }
        log.write("helper started pid=\(getpid())")
        handedOff = true
        let fd = listener
        Thread.detachNewThread { [self] in acceptLoop(fd) }
    }

    public var status: [String: Any] {
        let snapshot = withState { state in
            (state.running, state.running > 0 || state.lastCall.timeIntervalSinceNow > -3, state.paused)
        }
        return ["running": snapshot.0, "working": snapshot.1, "paused": snapshot.2,
                "grants": configuration.grants()]
    }
    func note(_ line: String) { log.write(line) }
    public var hasRunningCalls: Bool { withState { $0.running > 0 } }
    public var isStopping: Bool { withState { $0.stopping } }
    /// Standalone development helpers may idle out; an app-owned helper remains
    /// available while the feature is enabled and its owning app is alive.
    public var isIdle: Bool {
        withState { $0.running == 0 && max($0.lastCall, created).timeIntervalSinceNow < -15 * 60 }
    }

    /// Synchronous executor/effect callbacks must enqueue shutdown, not self-join.
    /// This guard also makes an accidental direct stop on a worker safe.
    private func inWorkerContext<T>(_ work: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[contextKey]
        dictionary[contextKey] = true
        defer {
            if let previous { dictionary[contextKey] = previous }
            else { dictionary.removeObject(forKey: contextKey) }
        }
        return try work()
    }

    /// Stops accepting, cancels calls, drains workers/reaping, cleans executor
    /// state, then releases socket/flock. Keep AppKit servicing until it returns.
    public func stop() {
        if Thread.current.threadDictionary[contextKey] != nil {
            if !withState({ $0.finished }) { Thread.detachNewThread { [self] in stop() } }
            return
        }
        condition.lock()
        if storage.withLock({ $0.stopping }) {
            while !storage.withLock({ $0.finished }) { condition.wait() }
            condition.unlock()
            return
        }
        let cancellation = storage.withLock { state in
            state.stopping = true
            state.stopGeneration += 1
            state.recentAgents = state.recentAgents.filter { $0.value.timeIntervalSinceNow > -3 }
            return (state.listener, Set(state.active.keys).union(state.recentAgents.keys))
        }
        condition.unlock()
        inWorkerContext {
            sessions.stop(cancellation.1)
            executor.cancel(agentKeys: cancellation.1)
        }
        if cancellation.0 >= 0 { Darwin.shutdown(cancellation.0, SHUT_RDWR) }
        accepting.wait()
        condition.lock()
        while storage.withLock({ $0.running > 0 }) { condition.wait() }
        condition.unlock()
        // Closing workers and this shutdown snapshot share an execution gate, so
        // an fd cannot be closed/reused between the snapshot and shutdown().
        connectionExecution.lock()
        let idle = withState { $0.connections }
        for fd in idle { Darwin.shutdown(fd, SHUT_RDWR) }
        connectionExecution.unlock()
        workers.wait()
        inWorkerContext { executor.shutdown() }
        let resources = withState { state in
            let result = (state.listener, state.lockFD, state.started)
            state.listener = -1
            state.lockFD = -1
            return result
        }
        if resources.2 { log.write("helper stopped") }
        if resources.0 >= 0 { close(resources.0) }
        if resources.2 { unlink(socketPath) }
        if resources.1 >= 0 { flock(resources.1, LOCK_UN); close(resources.1) }
        let callback = withState { state in
            state.finished = true
            let callback = state.onShutdown
            state.onShutdown = nil
            condition.broadcast()
            return callback
        }
        callback?()
    }

    private func acceptLoop(_ listener: Int32) {
        defer { accepting.leave() }
        while !isStopping {
            var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 200) > 0 else { continue }
            if isStopping { return }
            let fd = accept(listener, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                return
            }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let enrolled = withState { state in
                guard !state.stopping else { return false }
                state.connections.insert(fd)
                workers.enter()
                return true
            }
            guard enrolled else { close(fd); return }
            Thread.detachNewThread { [self] in inWorkerContext { handle(fd) } }
        }
    }

    private func handle(_ fd: Int32) {
        defer {
            connectionExecution.lock()
            _ = withState { $0.connections.remove(fd) }
            close(fd)
            connectionExecution.unlock()
            workers.leave()
        }
        do {
            let uid = UnixSocket.peerUID(fd)
            let pid = UnixSocket.peerPID(fd)
            let message = try Wire.read(from: fd, deadline: Date().addingTimeInterval(10))
            let answer = answer(
                message, peerPID: pid ?? 0, peerUID: uid ?? uid_t.max,
                abandoned: {
                    var poller = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
                    return poll(&poller, 1, 0) > 0
                })
            do { try Wire.write(answer, to: fd, deadline: Date().addingTimeInterval(10)) } catch WireError.frameTooLarge
            {
                try Wire.write(
                    Wire.error(id: message["id"] ?? NSNull(), name: "responseTooLarge"), to: fd,
                    deadline: Date().addingTimeInterval(10))
            }
            if message["method"] as? String == "shutdown", uid == getuid(), answer["error"] == nil {
                requestShutdown()
            }
        } catch { /* No UI contents or typed text in logs. A malformed client is closed. */  }
    }

    public func requestShutdown() {
        // A stuck executor must not hold the single-instance lock forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + Limits.callTimeout + 10) { [weak self] in
            guard let self else { return }
            let stuck = self.withState { !$0.finished }
            if stuck { _exit(1) }
        }
        Thread.detachNewThread { [self] in stop() }
    }

    /// Public for deterministic authentication/ancestry tests; real callers enter
    /// through the socket, whose kernel supplies pid and uid (never request params).
    /// Direct control-method callers are not socket-worker enrollments; this seam
    /// does not make arbitrary control callbacks part of the shutdown drain.
    public func answer(
        _ message: [String: Any], peerPID: pid_t, peerUID: uid_t,
        abandoned: @escaping @Sendable () -> Bool = { false }
    ) -> [String: Any] {
        inWorkerContext {
            answerOnWorker(message, peerPID: peerPID, peerUID: peerUID, abandoned: abandoned)
        }
    }

    private func answerOnWorker(
        _ message: [String: Any], peerPID: pid_t, peerUID: uid_t,
        abandoned: @escaping @Sendable () -> Bool
    ) -> [String: Any] {
        let id = message["id"] ?? NSNull()
        guard peerUID == getuid() else { return Wire.error(id: id, name: "notAuthenticated") }
        let validID: Bool
        if let number = id as? NSNumber {
            validID = CFGetTypeID(number) != CFBooleanGetTypeID()
        } else {
            validID = id is String
        }
        guard validID, message["jsonrpc"] as? String == "2.0" else {
            return Wire.error(id: NSNull(), name: "invalidRequest")
        }
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "ping", "shutdown":
            let snapshot = status
            return Wire.result(
                id: id,
                [
                    "pid": getpid(), "version": ComputerUseVersion.current,
                    "apiVersion": Limits.apiVersion, "paused": snapshot["paused"]!, "running": snapshot["running"]!,
                ])
        case "status": return Wire.result(id: id, status)
        case "pause", "resume":
            do {
                try setPaused(method == "pause")
                return Wire.result(id: id, status)
            } catch {
                return Wire.reply(id: id, exit: 1, stdout: "", stderr: "Could not save Computer Use pause state.\n")
            }
        case "stop":
            stopCurrentTurn()
            return Wire.result(id: id, status)
        case "allow":
            guard let grant = params["grant"] as? String, !grant.isEmpty else {
                return Wire.error(id: id, name: "invalidRequest")
            }
            do {
                try configuration.allow(grant)
                return Wire.result(id: id, status)
            } catch { return Wire.error(id: id, name: "permissionRequestFailed") }
        case "request": break
        default: return Wire.error(id: id, name: "methodNotFound")
        }
        let argv = params["argv"] as? [String] ?? []
        var json = argv.contains("--json")
        func failed(_ error: HarnessError) -> [String: Any] {
            let outcome = ToolOutcome.failure(error, json: json)
            return Wire.reply(id: id, exit: outcome.exit, stdout: outcome.stdout, stderr: outcome.stderr)
        }
        // Control methods are for the main app/person; only TOOL requests require
        // term-llm ancestry. A same-uid process may always Stop/Pause the helper.
        guard
            FileManager.default.fileExists(atPath: stateDirectory.appendingPathComponent("allow-any-caller").path)
                || sessions.callerAllowed(peerPID)
        else { return failed(Errors.make("caller_refused")) }
        guard params["callerApi"] as? String == Limits.apiVersion,
            params["clientVersion"] as? String == ComputerUseVersion.current
        else {
            return Wire.error(id: id, name: "versionMismatch")
        }
        guard let ms = params["deadlineMs"] as? NSNumber, ms.doubleValue.isFinite,
            ms.doubleValue / 1000 > Date().timeIntervalSince1970
        else { return Wire.error(id: id, name: "deadlineExceeded") }
        let deadline = min(
            Date(timeIntervalSince1970: ms.doubleValue / 1000), Date().addingTimeInterval(Limits.callTimeout))
        do {
            var parsed = try ToolParser.parse(argv)
            json = parsed.arguments["json"] as? Bool == true
            if parsed.arguments["help"] as? Bool == true {
                parsed = try ToolParser.parse(parsed.name == "help" ? ["help"] : ["help", parsed.name])
                parsed.arguments["json"] = json
            }
            let began = Date()
            // `parsed.name` comes from the static table, never from user content.
            defer { log.write("call \(parsed.name) durationMs=\(Int(Date().timeIntervalSince(began) * 1000))") }
            let env = Wire.passed(params["env"] as? [String: String] ?? [:])
            let kind = AdmissionKind(name: parsed.name)
            let lifecycle = kind == .lifecycle
            let admission: Admission
            do {
                admission = try admit(peerPID: peerPID, environment: env, kind: kind)
            } catch let refusal as AdmissionRefusal {
                // Only a refused admission certifies that no call effects ran.
                // Running-call cancellation must remain a non-retryable result.
                return refusal.wireReply(id: id)
            }
            let agent = admission.agent
            awake.begin()
            defer {
                awake.end()
                finish(admission, remember: ToolParser.tools.contains { $0.name == parsed.name })
            }
            let isTool = ToolParser.tools.contains { $0.name == parsed.name }
            @Sendable func cancellation() -> HarnessError? {
                let (stop, pause) = self.withState {
                    ($0.stopping, $0.paused || $0.pauseGeneration != admission.pauseGeneration)
                }
                if stop { return Errors.make("helper_stopped") }
                if self.sessions.isStopped(agent) { return Errors.make("stopped_by_user") }
                if isTool && pause { return Errors.make("paused") }
                if self.sessions.hostGone(agent) || self.sessions.cancellationGeneration(agent) != admission.cancellationGeneration {
                    return Errors.make("agent_left")
                }
                if abandoned() || Date() >= deadline { return Errors.make("request_timed_out") }
                return nil
            }
            if !lifecycle, let error = cancellation() { throw error }
            var arguments = parsed.arguments
            let stdin = params["stdin"] as? String
            if let param = parsed.tool.stdin, arguments[param] == nil || arguments[param] as? String == "-" {
                guard let stdin else { throw NeedStdin() }
                let text = stdin.hasSuffix("\n") ? String(stdin.dropLast()) : stdin
                arguments.removeValue(forKey: param)
                if !text.isEmpty { arguments[param] = text }
            }
            let call = ToolCallRequest(
                name: parsed.name, arguments: arguments, stdin: stdin, environment: env, agent: agent,
                sessions: sessions,
                cwd: params["cwd"] as? String ?? "/", deadline: deadline, abandoned: { cancellation() != nil },
                withCleanupQueue: { path, work in try self.appQueue(path).run(work) },
                withAppQueue: { path, work in
                    let queue = self.appQueue(path)
                    return try queue.run(abandoned: { cancellation() != nil }, work)
                })
            let outcome: ToolOutcome
            do {
                outcome = try executor.execute(call)
                if !lifecycle, let error = cancellation() { throw error }
            } catch is NeedStdin { throw NeedStdin() } catch {
                if !lifecycle, let reason = cancellation() { throw reason }
                throw error
            }
            return Wire.reply(id: id, exit: outcome.exit, stdout: outcome.stdout, stderr: outcome.stderr)
        } catch is NeedStdin { return Wire.result(id: id, ["needStdin": true]) } catch let error as HarnessError {
            return failed(error)
        } catch { return failed(Errors.serverError("Tool execution failed.")) }
    }

    /// Pure production admission seam: no socket, power, tool or UI effects.
    /// Sampling is outside bookkeeping. Revalidate all server baselines before
    /// enrollment so Stop/shutdown cannot miss a late, blocked provider result.
    enum AdmissionKind: Sendable, Equatable {
        case ordinary, lifecycle
        init(name: String) {
            self = ["help", "skill", "turn-started", "turn-ended"].contains(name) ? .lifecycle : .ordinary
        }
    }
    /// Distinct from cancellation of an admitted call: only this no-effects
    /// refusal may be mapped to a retryable transport error.
    enum AdmissionRefusal: Error, Equatable, Sendable {
        case stopping
        func wireReply(id: Any) -> [String: Any] {
            switch self {
            case .stopping: return Wire.error(id: id, name: "stopping")
            }
        }
    }
    struct Admission: Sendable {
        let agent: AgentSession
        let pauseGeneration: Int
        let cancellationGeneration: Int
    }
    func admit(peerPID: pid_t, environment: [String: String], kind: AdmissionKind = .ordinary) throws -> Admission {
        let baseline = try withState { state in
            guard !state.stopping else { throw AdmissionRefusal.stopping }
            return (state.pauseGeneration, state.stopGeneration)
        }
        let agent = sessions.agent(peerPID: peerPID, env: environment)
        let cancelled = sessions.cancellationGeneration(agent)
        let drain = try withState { state in
            guard !state.stopping else { throw AdmissionRefusal.stopping }
            guard kind == .lifecycle || state.stopGeneration == baseline.1 else { throw Errors.make("stopped_by_user") }
            workers.enter() // also covers direct callers and the working-effect drain
            state.running += 1
            state.active[agent.key, default: 0] += 1
            state.lastCall = Date()
            return enqueueWorking(true, state: &state)
        }
        if drain { drainWorking() }
        return Admission(agent: agent, pauseGeneration: baseline.0, cancellationGeneration: cancelled)
    }

    func finish(_ admission: Admission, remember: Bool) {
        defer { workers.leave() }
        let drain = withState { state in
            state.running -= 1
            state.active[admission.agent.key, default: 1] -= 1
            if state.active[admission.agent.key] == 0 { state.active.removeValue(forKey: admission.agent.key) }
            if remember {
                state.recentAgents = state.recentAgents.filter { $0.value.timeIntervalSinceNow > -3 }
                state.recentAgents[admission.agent.key] = Date()
            }
            state.lastCall = Date()
            let drain = enqueueWorking(state.running > 0, state: &state)
            condition.broadcast()
            return drain
        }
        if drain { drainWorking() }
    }

    private func enqueueWorking(_ working: Bool, state: inout State) -> Bool {
        state.workingEffects.append(working)
        guard !state.drainingWorking else { return false }
        state.drainingWorking = true
        return true
    }
    private func drainWorking() {
        inWorkerContext {
            while let effect = withState({ state -> Bool? in
                guard !state.workingEffects.isEmpty else {
                    state.drainingWorking = false
                    return nil
                }
                return state.workingEffects.removeFirst()
            }) {
                configuration.onWorking(effect)
            }
        }
    }

    private func appQueue(_ path: String) -> AppFIFO {
        withState { state in
            let queue = state.queues[path] ?? AppFIFO()
            state.queues[path] = queue
            return queue
        }
    }
    /// Esc and the same-uid stop control deliberately use exactly one code path.
    public func stopCurrentTurn() {
        condition.lock()
        let keys: Set<String>? = storage.withLock { state in
            guard !state.stopping else { return nil }
            state.stopGeneration += 1
            state.recentAgents = state.recentAgents.filter { $0.value.timeIntervalSinceNow > -3 }
            workers.enter() // cancellation callbacks must also drain before shutdown
            return Set(state.active.keys).union(state.recentAgents.keys)
        }
        // Lock order: condition -> (storage, then released) -> Sessions -> Agent.
        // Sessions.stop is provider/callback-free. Publish its marks before a new
        // admission can read the advanced baseline, but never hold storage here.
        if let keys { sessions.stop(keys) }
        condition.unlock()
        guard let keys else { return }
        defer { workers.leave() }
        inWorkerContext {
            // Pending questions retire even after the original call returned.
            executor.cancel(agentKeys: keys)
        }
    }
    public func reapSessions() {
        let enrolled = withState { state in
            guard !state.stopping else { return false }
            workers.enter()
            return true
        }
        guard enrolled else { return }
        defer { workers.leave() }
        inWorkerContext {
            for agent in sessions.reap() {
                executor.agentExited(agent, withAppQueue: { path, work in try self.appQueue(path).run(work) })
            }
        }
    }
    private func setPaused(_ value: Bool) throws {
        // Preserve persistence/commit order without making status or Stop wait
        // for filesystem operations. Failed writes leave memory/generation intact.
        persistenceExecution.lock()
        defer { persistenceExecution.unlock() }
        let flag = stateDirectory.appendingPathComponent("paused")
        if value {
            try UnixSocket.makeOwnFolder(stateDirectory.path)
            try Data().write(to: flag, options: .atomic)
            chmod(flag.path, 0o600)
        } else if FileManager.default.fileExists(atPath: flag.path) {
            try FileManager.default.removeItem(at: flag)
        }
        withState { state in
            if value { state.pauseGeneration += 1 }
            state.paused = value
        }
    }
}

@MainActor
private final class HelperMainResources {
    var hostTimer: DispatchSourceTimer?
}

public enum HelperMain {
    // DispatchSource's legacy handler API does not require Sendable, so inline
    // closures in run() inherit MainActor and trap when the global queue fires.
    // Build explicitly Sendable callbacks outside that actor-isolated context.
    static func shutdownHandler(server: HelperServer) -> @Sendable () -> Void {
        { server.requestShutdown() }
    }

    static func maintenanceHandler(
        server: HelperServer, configuration: HelperConfiguration
    ) -> @Sendable () -> Void {
        let pid = configuration.environment["TERM_LLM_COMPUTER_HOST_PID"].flatMap(Int32.init)
        let host = pid.flatMap(ProcessIdentity.lookup)
        return {
            server.reapSessions()
            configuration.onMaintenance()
            // Only an app-owned helper is started again by its owner.
            if pid != nil, !server.hasRunningCalls, configuration.wantsRelaunch() {
                server.note("relaunch to read a new permission grant")
                server.requestShutdown()
            }
            if let pid {
                if host == nil || ProcessIdentity.lookup(pid)?.started != host?.started { server.requestShutdown() }
            } else if server.isIdle {
                server.requestShutdown()
            }
        }
    }

    /// Call on the main thread: it becomes the AppKit loop.
    @MainActor
    public static func run(executor: ToolExecutor) -> Never {
        run(executor: executor, configuration: HelperConfiguration())
    }
    @MainActor
    public static func run(executor: ToolExecutor, configuration: HelperConfiguration) -> Never {
        let server = HelperServer(executor: executor, configuration: configuration)
        server.onShutdown = { MainThread.stop() }
        configuration.installStop {
            DispatchQueue.global().async { server.stopCurrentTurn() }
        }
        var signals: [DispatchSourceSignal] = []
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler(handler: shutdownHandler(server: server))
            source.resume()
            signals.append(source)
        }
        let resources = HelperMainResources()
        MainThread.run {
            configuration.onStarted()
            do { try server.start() } catch {
                // Startup rollback has completed, but executor/UI teardown (or a
                // concurrent Stop) still needs a servicing AppKit loop to drain.
                Thread.detachNewThread {
                    server.stop()
                    MainThread.stop()
                }
                return
            }
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler(handler: maintenanceHandler(server: server, configuration: configuration))
            timer.resume()
            resources.hostTimer = timer
        }
        resources.hostTimer?.cancel()
        // A startup failure never bound/unlinked another helper's socket.
        server.stop()
        for source in signals { source.cancel() }
        exit(0)
    }
}
