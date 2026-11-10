import ComputerUseCore
import ComputerUseSystem
import CoreFoundation
import Darwin
import Foundation

public enum ComputerUseHelperInfo { public static let version = ComputerUseVersion.current }

/// Pluggable permission hooks keep the shell and main app free of TCC requests.
/// `allow` runs on a worker: use MainThread for any permission UI it needs.
public struct HelperConfiguration {
    public var environment: [String: String]
    public var grants: () -> [String: Bool]
    public var allow: (String) throws -> Void
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        grants: @escaping () -> [String: Bool] = { [:] },
        allow: @escaping (String) throws -> Void = { _ in
            throw Errors.serverError("Permission requests are not implemented yet in this Computer Use shell.")
        }
    ) {
        self.environment = environment
        self.grants = grants
        self.allow = allow
    }
}

/// One helper per socket. `start`/`stop` also work without AppKit for socket tests.
public final class HelperServer {
    public let sessions: Sessions
    public let configuration: HelperConfiguration
    private let executor: ToolExecutor
    private let condition = NSCondition()
    private let workers = DispatchGroup()
    private let accepting = DispatchGroup()
    private let awake = DisplayAwake()
    private let log: HelperLog
    private var listener: Int32 = -1
    private var lockFD: Int32 = -1
    private var connections: Set<Int32> = []
    private var queues: [String: AppFIFO] = [:]
    private var running = 0
    private var active: [String: Int] = [:]
    private var recentAgents: [String: Date] = [:]
    private var lastCall = Date.distantPast
    private let created = Date()
    private var stopping = false
    private var paused: Bool
    private var pauseGeneration = 0
    private var started = false
    private var finished = false
    private let state: URL
    private let socketPath: String
    public var onShutdown: (() -> Void)?

    public init(
        executor: ToolExecutor = StubToolExecutor(), configuration: HelperConfiguration = HelperConfiguration(),
        sessions: Sessions = Sessions()
    ) {
        self.executor = executor
        self.configuration = configuration
        self.sessions = sessions
        log = HelperLog(environment: configuration.environment)
        state = Paths.stateDirectory(env: configuration.environment)
        socketPath = Paths.socketPath(env: configuration.environment)
        paused = FileManager.default.fileExists(atPath: state.appendingPathComponent("paused").path)
    }
    deinit { if lockFD >= 0 { close(lockFD) } }

    /// Throws EWOULDBLOCK if a helper already owns this socket. Never steals its lock.
    public func start() throws {
        condition.lock()
        defer { condition.unlock() }
        guard !started else { return }
        guard !stopping else { throw WireError.closed }
        try UnixSocket.makeOwnFolder(state.path)
        try UnixSocket.makeOwnFolder((socketPath as NSString).deletingLastPathComponent)
        let lockPath = Paths.lockPath(env: configuration.environment)
        lockFD = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw WireError.system("open lock", errno) }
        var info = stat()
        guard fstat(lockFD, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG else {
            close(lockFD)
            lockFD = -1
            throw WireError.system("lock ownership", EPERM)
        }
        let until = Date().addingTimeInterval(5)
        while flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            if let probe = try? UnixSocket.connect(socketPath, timeout: 0.1) {
                close(probe)
                close(lockFD)
                lockFD = -1
                throw WireError.system("helper already running", EWOULDBLOCK)
            }
            if Date() >= until {
                close(lockFD)
                lockFD = -1
                throw WireError.system("flock", EWOULDBLOCK)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        do { listener = try UnixSocket.listen(socketPath) } catch {
            close(lockFD)
            lockFD = -1
            throw error
        }
        started = true
        log.write("helper started pid=\(getpid())")
        accepting.enter()
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    public var status: [String: Any] {
        condition.lock()
        let value: [String: Any] = [
            "running": running, "working": running > 0 || lastCall.timeIntervalSinceNow > -3,
            "paused": paused,
        ]
        condition.unlock()
        return value.merging(["grants": configuration.grants()]) { _, new in new }
    }
    public var isStopping: Bool {
        condition.lock()
        defer { condition.unlock() }
        return stopping
    }
    /// Standalone development helpers may idle out; an app-owned helper remains
    /// available while the feature is enabled and its owning app is alive.
    public var isIdle: Bool {
        condition.lock()
        defer { condition.unlock() }
        return running == 0 && max(lastCall, created).timeIntervalSinceNow < -15 * 60
    }

    /// Stops accepting, cancels calls, drains workers, cleans executor state, then
    /// removes the socket and releases flock. Keep AppKit running until this returns.
    public func stop() {
        condition.lock()
        if stopping {
            while !finished { condition.wait() }
            condition.unlock()
            return
        }
        stopping = true
        let fd = listener
        condition.unlock()
        // A listener shutdown wakes accept; no fd is closed/reused under a worker.
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
        accepting.wait()
        condition.lock()
        // Frame readers are not executing a tool. Wake them now; running executors
        // see abandoned() and may still send a final cancellation reply.
        while running > 0 { condition.wait() }
        let idle = connections
        condition.unlock()
        for fd in idle { Darwin.shutdown(fd, SHUT_RDWR) }
        workers.wait()
        executor.shutdown()
        if started { log.write("helper stopped") }
        condition.lock()
        if listener >= 0 {
            close(listener)
            listener = -1
        }
        if started { unlink(socketPath) }
        if lockFD >= 0 {
            flock(lockFD, LOCK_UN)
            close(lockFD)
            lockFD = -1
        }
        finished = true
        condition.broadcast()
        condition.unlock()
        onShutdown?()
    }

    private func acceptLoop() {
        defer { accepting.leave() }
        while !isStopping {
            // Poll also handles a shutdown on platforms where accept is not woken.
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
            condition.lock()
            connections.insert(fd)
            workers.enter()
            condition.unlock()
            Thread.detachNewThread { [self] in handle(fd) }
        }
    }

    private func handle(_ fd: Int32) {
        defer {
            condition.lock()
            connections.remove(fd)
            close(fd)
            condition.unlock()
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
            self.condition.lock()
            let stuck = !self.finished
            self.condition.unlock()
            if stuck { _exit(1) }
        }
        Thread.detachNewThread { [self] in stop() }
    }

    /// Public for deterministic authentication/ancestry tests; real callers enter
    /// through the socket, whose kernel supplies pid and uid (never request params).
    public func answer(
        _ message: [String: Any], peerPID: pid_t, peerUID: uid_t,
        abandoned: @escaping () -> Bool = { false }
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
            // Hold the state lock through marking sessions, so a concurrently
            // starting action cannot fall between the snapshot and the Stop mark.
            condition.lock()
            recentAgents = recentAgents.filter { $0.value.timeIntervalSinceNow > -3 }
            // Stop remains useful during the menu's three-second Working grace
            // period between an agent's commands, not just during a socket call.
            sessions.stop(Set(active.keys).union(recentAgents.keys))
            condition.unlock()
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
            FileManager.default.fileExists(atPath: state.appendingPathComponent("allow-any-caller").path)
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
            condition.lock()
            if stopping {
                condition.unlock()
                return Wire.error(id: id, name: "stopping")
            }
            let agent = sessions.agent(peerPID: peerPID, env: env)
            let pauseAtStart = pauseGeneration
            let cancelledAtStart = sessions.cancellationGeneration(agent)
            running += 1
            active[agent.key, default: 0] += 1
            lastCall = Date()
            condition.unlock()
            awake.begin()
            defer {
                awake.end()
                condition.lock()
                running -= 1
                active[agent.key, default: 1] -= 1
                if active[agent.key] == 0 { active.removeValue(forKey: agent.key) }
                if ToolParser.tools.contains(where: { $0.name == parsed.name }) {
                    recentAgents = recentAgents.filter { $0.value.timeIntervalSinceNow > -3 }
                    recentAgents[agent.key] = Date()
                }
                lastCall = Date()
                condition.broadcast()
                condition.unlock()
            }
            let isTool = ToolParser.tools.contains { $0.name == parsed.name }
            let lifecycle = ["help", "skill", "turn-started", "turn-ended"].contains(parsed.name)
            func cancellation() -> HarnessError? {
                self.condition.lock()
                let stop = self.stopping
                let pause = self.paused || self.pauseGeneration != pauseAtStart
                self.condition.unlock()
                if stop { return Errors.make("helper_stopped") }
                if self.sessions.isStopped(agent) { return Errors.make("stopped_by_user") }
                if isTool && pause { return Errors.make("paused") }
                if self.sessions.hostGone(agent) || self.sessions.cancellationGeneration(agent) != cancelledAtStart {
                    return Errors.make("agent_left")
                }
                if abandoned() || Date() >= deadline { return Errors.make("request_timed_out") }
                return nil
            }
            if !lifecycle, let error = cancellation() { throw error }
            if isTool, sessions.hasEnded(agent) { throw Errors.make("turn_ended") }
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
                withAppQueue: { path, work in
                    self.condition.lock()
                    let queue = self.queues[path] ?? AppFIFO()
                    self.queues[path] = queue
                    self.condition.unlock()
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

    private func setPaused(_ value: Bool) throws {
        condition.lock()
        defer { condition.unlock() }
        let flag = state.appendingPathComponent("paused")
        if value {
            try UnixSocket.makeOwnFolder(state.path)
            try Data().write(to: flag, options: .atomic)
            chmod(flag.path, 0o600)
            pauseGeneration += 1
        } else if FileManager.default.fileExists(atPath: flag.path) {
            try FileManager.default.removeItem(at: flag)
        }
        paused = value
    }
}

public enum HelperMain {
    public static func run(executor: ToolExecutor) -> Never {
        run(executor: executor, configuration: HelperConfiguration())
    }
    public static func run(executor: ToolExecutor, configuration: HelperConfiguration) -> Never {
        let server = HelperServer(executor: executor, configuration: configuration)
        server.onShutdown = { MainThread.stop() }
        var signals: [DispatchSourceSignal] = []
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { server.requestShutdown() }
            source.resume()
            signals.append(source)
        }
        var hostTimer: DispatchSourceTimer?
        MainThread.run {
            do { try server.start() } catch {
                MainThread.stop()
                return
            }
            let pid = configuration.environment["TERM_LLM_COMPUTER_HOST_PID"].flatMap(Int32.init)
            let host = pid.flatMap(ProcessIdentity.lookup)
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler {
                _ = server.sessions.reap()
                if let pid {
                    if host == nil || ProcessIdentity.lookup(pid)?.started != host?.started { server.requestShutdown() }
                } else if server.isIdle {
                    server.requestShutdown()
                }
            }
            timer.resume()
            hostTimer = timer
        }
        hostTimer?.cancel()
        // A startup failure never bound/unlinked another helper's socket.
        server.stop()
        for source in signals { source.cancel() }
        exit(0)
    }
}
