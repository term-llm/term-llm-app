import ComputerUseCore
import Darwin
import Foundation
import os
import XCTest

@testable import ComputerUseHelper

final class HelperTests: XCTestCase {
    private var home: URL!
    private var env: [String: String]!
    private var servers: [HelperServer] = []
    override func setUpWithError() throws {
        home = URL(fileURLWithPath: "/tmp/cu-\(UUID().uuidString.prefix(8))")
        env = [
            "TERM_LLM_COMPUTER_HOME": home.path,
            "TERM_LLM_COMPUTER_SOCKET": home.appendingPathComponent("helper.sock").path,
        ]
        try FileManager.default.createDirectory(
            at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data().write(to: home.appendingPathComponent("allow-any-caller"))
    }
    override func tearDownWithError() throws {
        for server in servers { server.stop() }
        servers = []
        try? FileManager.default.removeItem(at: home)
    }
    @discardableResult private func start(
        _ executor: ToolExecutor = StubToolExecutor(),
        sessions: Sessions = Sessions(), grants: @escaping @Sendable () -> [String: Bool] = { [:] },
        allow: @escaping @Sendable (String) throws -> Void = { _ in },
        onWorking: @escaping @Sendable (Bool) -> Void = { _ in }
    ) throws -> HelperServer {
        var configuration = HelperConfiguration(environment: env, grants: grants, allow: allow)
        configuration.onWorking = onWorking
        let server = HelperServer(
            executor: executor, configuration: configuration,
            sessions: sessions)
        try server.start()
        servers.append(server)
        return server
    }
    private func request(_ argv: [String], stdin: String? = nil, session: String = "test") -> [String: Any] {
        Wire.request(
            argv: argv, stdin: stdin, cwd: "/", env: ["TERM_LLM_SESSION_ID": session],
            deadline: Date().addingTimeInterval(5).timeIntervalSince1970, version: ComputerUseVersion.current)
    }
    private func connect() throws -> Int32 { try UnixSocket.connect(Paths.socketPath(env: env), timeout: 1) }
    private func roundTrip(_ message: [String: Any]) throws -> [String: Any] {
        let fd = try connect()
        defer { close(fd) }
        return try Wire.call(message, on: fd, deadline: Date().addingTimeInterval(3))
    }
    private func result(_ message: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(roundTrip(message)["result"] as? [String: Any])
    }
    func testStoppedBeforeStartupCannotBind() throws {
        let server = HelperServer(configuration: HelperConfiguration(environment: env))
        server.stop()
        XCTAssertThrowsError(try server.start())
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.socketPath(env: env)))
    }


    func testWorkingCallbackAggregatesConcurrentCallsAndStopUsesSharedPath() throws {
        let began = DispatchSemaphore(value: 0), first = DispatchSemaphore(value: 0), second = DispatchSemaphore(value: 0)
        let updates = HelperFixtureBox<[Bool]>([])
        let server = try start(ClosureExecutor { call in
            began.signal()
            _ = (call.agent.key == "one" ? first : second).wait(timeout: .now() + 3)
            return ToolOutcome()
        }, onWorking: { value in updates.update { $0.append(value) } })
        let one = try connect(), two = try connect()
        defer { close(one); close(two); first.signal(); second.signal() }
        try Wire.write(request(["click", "Demo", "0"], session: "one"), to: one)
        try Wire.write(request(["click", "Demo", "0"], session: "two"), to: two)
        XCTAssertEqual(began.wait(timeout: .now() + 2), .success); XCTAssertEqual(began.wait(timeout: .now() + 2), .success)
        first.signal(); _ = try Wire.read(from: one, deadline: Date().addingTimeInterval(2))
        XCTAssertEqual(server.status["running"] as? Int, 1)
        let afterOne = updates.value; XCTAssertEqual(afterOne, [true, true, true])
        server.stopCurrentTurn() // exactly the banner callback's shared control path
        second.signal(); _ = try Wire.read(from: two, deadline: Date().addingTimeInterval(2))
        let afterBoth = updates.value; XCTAssertEqual(afterBoth, [true, true, true, false])
        XCTAssertEqual(server.status["working"] as? Bool, true) // three-second grace
    }

    func testVersion() { XCTAssertFalse(ComputerUseHelperInfo.version.isEmpty) }
    func testSocketRoundTripAndModes() throws {
        let server = try start(grants: { ["Accessibility": false] })
        XCTAssertEqual(try result(request(["help"]))["exit"] as? Int, 0)
        XCTAssertTrue(
            try XCTUnwrap(result(request(["help"]))["stdout"] as? String).contains("term-llm-computer get_app_state"))
        let ping = try result(Wire.control("ping"))
        XCTAssertEqual(ping["pid"] as? Int, Int(getpid()))
        XCTAssertEqual(ping["version"] as? String, ComputerUseVersion.current)
        XCTAssertEqual(try result(Wire.control("status"))["grants"] as? [String: Bool], ["Accessibility": false])
        let socket = try FileManager.default.attributesOfItem(atPath: Paths.socketPath(env: env))
        XCTAssertEqual(socket[.posixPermissions] as? Int, 0o600)
        let directory = try FileManager.default.attributesOfItem(atPath: home.path)
        XCTAssertEqual(directory[.posixPermissions] as? Int, 0o700)
        XCTAssertFalse(server.isStopping)
        XCTAssertThrowsError(try start(), "The second helper must never steal the socket")
        XCTAssertEqual(
            try result(request(["skill"]))["stdout"] as? String,
            ComputerUseSkill.text + (ComputerUseSkill.text.hasSuffix("\n") ? "" : "\n"))
    }
    func testNeedStdinRoundTripAndExecutorThrow() throws {
        try start(
            ClosureExecutor { call in
                if call.name == "doctor", call.stdin == nil { throw NeedStdin() }
                return .text(call.arguments["text"] as? String ?? call.stdin ?? "", json: false)
            })
        XCTAssertEqual(try result(request(["paste", "TextEdit"]))["needStdin"] as? Bool, true)
        XCTAssertEqual(try result(request(["paste", "TextEdit"], stdin: "hello\n"))["stdout"] as? String, "hello\n")
        XCTAssertEqual(try result(request(["doctor"]))["needStdin"] as? Bool, true)
        XCTAssertEqual(try result(request(["doctor"], stdin: "a"))["stdout"] as? String, "a\n")
    }
    func testAbandonedOnClientClose() throws {
        let began = DispatchSemaphore(value: 0)
        let abandoned = DispatchSemaphore(value: 0)
        try start(
            ClosureExecutor { call in
                began.signal()
                let end = Date().addingTimeInterval(2)
                while !call.abandoned() && Date() < end { Thread.sleep(forTimeInterval: 0.005) }
                if call.abandoned() { abandoned.signal() }
                return ToolOutcome()
            })
        let fd = try connect()
        try Wire.write(request(["click", "TextEdit", "1"]), to: fd)
        XCTAssertEqual(began.wait(timeout: .now() + 2), .success)
        close(fd)
        XCTAssertEqual(abandoned.wait(timeout: .now() + 2), .success)
    }
    func testPauseStopAndNextTurn() throws {
        let began = DispatchSemaphore(value: 0)
        let blocking = LockedBool(true)
        let server = try start(
            ClosureExecutor { call in
                if call.name == "click", blocking.value {
                    began.signal()
                    while !call.abandoned() { Thread.sleep(forTimeInterval: 0.005) }
                    return ToolOutcome()
                }
                if call.name == "click" { return ToolOutcome(stdout: "done\n") }
                return try StubToolExecutor().execute(call)
            })
        let fd = try connect()
        defer { close(fd) }
        try Wire.write(request(["click", "TextEdit", "1"]), to: fd)
        XCTAssertEqual(began.wait(timeout: .now() + 2), .success)
        _ = try result(Wire.control("stop"))
        let stopped = try Wire.read(from: fd, deadline: Date().addingTimeInterval(2))["result"] as? [String: Any]
        XCTAssertTrue((stopped?["stderr"] as? String ?? "").contains("user stopped"))
        blocking.value = false
        XCTAssertTrue(
            try XCTUnwrap(result(request(["click", "TextEdit", "1"]))["stderr"] as? String).contains("user stopped"))
        _ = try result(request(["turn-started"]))
        XCTAssertEqual(try result(request(["click", "TextEdit", "1"]))["exit"] as? Int, 0)
        _ = try result(Wire.control("pause"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("paused").path))
        XCTAssertEqual(server.status["paused"] as? Bool, true)
        XCTAssertTrue(
            try XCTUnwrap(result(request(["click", "TextEdit", "1"]))["stderr"] as? String).contains("user paused"))
        XCTAssertEqual(try result(request(["help"]))["exit"] as? Int, 0)
        // Restart preserves Pause.
        server.stop()
        _ = try start()
        XCTAssertEqual(try result(Wire.control("ping"))["paused"] as? Bool, true)
        _ = try result(Wire.control("resume"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("paused").path))
    }
    func testAuthVersionDeadlineAndCallerGate() throws {
        try FileManager.default.removeItem(at: home.appendingPathComponent("allow-any-caller"))
        let processes = ProcessTable([
            4: ProcessIdentity(pid: 4, parent: 3, path: "/bin/term-llm-computer", started: 1),
            3: ProcessIdentity(pid: 3, parent: 2, path: "/bin/sh", started: 1),
            2: ProcessIdentity(pid: 2, parent: 1, path: "/bin/other", started: 1),
        ])
        let server = try start(sessions: Sessions(process: processes.get))
        let auth = server.answer(request(["help"]), peerPID: 4, peerUID: getuid() + 1)
        XCTAssertEqual((auth["error"] as? [String: Any])?["errorName"] as? String, "notAuthenticated")
        let refused = server.answer(request(["help", "--json"]), peerPID: 4, peerUID: getuid())
        XCTAssertTrue(((refused["result"] as? [String: Any])?["stdout"] as? String ?? "").contains("caller_refused"))
        XCTAssertNotNil(server.answer(Wire.control("status"), peerPID: 4, peerUID: getuid())["result"])
        processes.records[2] = ProcessIdentity(pid: 2, parent: 1, path: "/app/term-llm", started: 1)
        XCTAssertEqual(
            (server.answer(request(["help"]), peerPID: 4, peerUID: getuid())["result"] as? [String: Any])?["exit"]
                as? Int, 0)
        var wrong = request(["help"])
        var params = wrong["params"] as! [String: Any]
        params["clientVersion"] = "old"
        wrong["params"] = params
        XCTAssertEqual(
            (server.answer(wrong, peerPID: 4, peerUID: getuid())["error"] as? [String: Any])?["errorName"] as? String,
            "versionMismatch")
        params["clientVersion"] = ComputerUseVersion.current
        params["deadlineMs"] = 0
        wrong["params"] = params
        XCTAssertEqual(
            (server.answer(wrong, peerPID: 4, peerUID: getuid())["error"] as? [String: Any])?["errorName"] as? String,
            "deadlineExceeded")
        var invalid = Wire.control("ping")
        invalid["id"] = true
        XCTAssertNotNil(server.answer(invalid, peerPID: 4, peerUID: getuid())["error"])
    }
    func testSessionKeysHostsAndOrphanedShell() {
        let table = ProcessTable([
            9: ProcessIdentity(pid: 9, parent: 8, path: "/bin/term-llm-computer", started: 1),
            8: ProcessIdentity(pid: 8, parent: 7, path: "/bin/-zsh", started: 2),
            7: ProcessIdentity(pid: 7, parent: 6, path: "/A.app/Contents/MacOS/term-llm", started: 3),
            6: ProcessIdentity(pid: 6, parent: 0, path: "/Host.app/Contents/MacOS/Host", started: 4),
        ])
        let sessions = Sessions(process: table.get)
        let agent = sessions.agent(peerPID: 9, env: [:])
        XCTAssertEqual(agent.key, "7:3.0")
        XCTAssertEqual(agent.hosts, ["/A.app", "/Host.app"])
        XCTAssertTrue(agent === sessions.agent(peerPID: 9, env: [:]))
        XCTAssertEqual(
            sessions.agent(
                peerPID: 9, env: ["TERM_LLM_SESSION_ID": "primary", "TERM_LLM_COMPUTER_SESSION": "fallback"]
            ).key, "primary")
        XCTAssertEqual(sessions.agent(peerPID: 9, env: ["TERM_LLM_COMPUTER_SESSION": "fallback"]).key, "fallback")
        table.records.removeValue(forKey: 7)
        table.records[8] = ProcessIdentity(pid: 8, parent: 6, path: "/bin/-zsh", started: 2)
        XCTAssertTrue(sessions.hostGone(agent))
        XCTAssertTrue(sessions.agent(peerPID: 9, env: [:]).exited)
        XCTAssertEqual(sessions.reap().map(\.key), [agent.key])
    }
    func testPauseCancelsAnInFlightCallAndHostDeathCancels() throws {
        let began = DispatchSemaphore(value: 0)
        let server = try start(
            ClosureExecutor { call in
                began.signal()
                while !call.abandoned() { Thread.sleep(forTimeInterval: 0.005) }
                return ToolOutcome()
            })
        let fd = try connect()
        defer { close(fd) }
        try Wire.write(request(["click", "TextEdit", "1"]), to: fd)
        XCTAssertEqual(began.wait(timeout: .now() + 2), .success)
        _ = try result(Wire.control("pause"))
        let response = try Wire.read(from: fd, deadline: Date().addingTimeInterval(2))["result"] as? [String: Any]
        XCTAssertTrue((response?["stderr"] as? String ?? "").contains("user paused"))
        server.stop()
        // Same cancellation seam also observes a pid reused for a new process.
        let table = ProcessTable([
            3: ProcessIdentity(pid: 3, parent: 2, path: "/bin/client", started: 1),
            2: ProcessIdentity(pid: 2, parent: 0, path: "/bin/term-llm", started: 2),
        ])
        let sessions = Sessions(process: table.get)
        let agent = sessions.agent(peerPID: 3, env: [:])
        XCTAssertFalse(sessions.hostGone(agent))
        table.records[2] = ProcessIdentity(pid: 2, parent: 0, path: "/bin/term-llm", started: 3)
        XCTAssertTrue(sessions.hostGone(agent))
    }
    func testStopBetweenCallsAndLogPrivacy() throws {
        try start(
            ClosureExecutor { call in
                if ["click", "type_text"].contains(call.name) { return ToolOutcome() }
                return try StubToolExecutor().execute(call)
            })
        _ = try result(request(["type_text", "TextEdit", "private-sentinel-never-log"]))
        _ = try result(Wire.control("stop"))
        XCTAssertTrue(
            try XCTUnwrap(result(request(["click", "TextEdit", "1"]))["stderr"] as? String).contains("user stopped"))
        _ = try result(request(["turn-started"]))
        XCTAssertEqual(try result(request(["click", "TextEdit", "1"]))["exit"] as? Int, 0)
        let log = try String(contentsOfFile: Paths.logPath(env: env), encoding: .utf8)
        XCTAssertTrue(log.contains("call type_text"))
        XCTAssertFalse(log.contains("private-sentinel"))
        XCTAssertFalse(log.contains("TextEdit"))
    }
    func testAllowHookAndShutdown() throws {
        let allowed = LockedBool(false)
        let server = try start(allow: { name in if name == "Accessibility" { allowed.value = true } })
        _ = try result(Wire.control("allow", params: ["grant": "Accessibility"]))
        XCTAssertTrue(allowed.value)
        _ = try result(Wire.control("shutdown"))
        let end = Date().addingTimeInterval(2)
        while !server.isStopping && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(server.isStopping)
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.socketPath(env: env)))
    }
    func testFIFOArrivalOrderAndCancellation() throws {
        let queue = AppFIFO()
        let blocked = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchGroup()
        let order = LockedArray()
        done.enter()
        DispatchQueue.global().async {
            try? queue.run {
                blocked.signal()
                release.wait()
                order.append(0)
            }
            done.leave()
        }
        XCTAssertEqual(blocked.wait(timeout: .now() + 1), .success)
        for index in 1...3 {
            done.enter()
            DispatchQueue.global().async {
                try? queue.run { order.append(index) }
                done.leave()
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        XCTAssertThrowsError(try queue.run(abandoned: { true }) { XCTFail("Cancelled waiter ran") })
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(order.values, [0, 1, 2, 3])
    }
}

private struct ClosureExecutor: ToolExecutor {
    let work: @Sendable (ToolCallRequest) throws -> ToolOutcome
    init(_ work: @escaping @Sendable (ToolCallRequest) throws -> ToolOutcome) { self.work = work }
    func execute(_ call: ToolCallRequest) throws -> ToolOutcome { try work(call) }
}
private final class ProcessTable: Sendable {
    private let stored: OSAllocatedUnfairLock<[pid_t: ProcessIdentity]>
    var records: [pid_t: ProcessIdentity] {
        get { stored.withLock { $0 } }
        set { stored.withLock { $0 = newValue } }
    }
    init(_ records: [pid_t: ProcessIdentity]) { stored = OSAllocatedUnfairLock(initialState: records) }
    var get: Sessions.ProcessProvider { { [self] pid in stored.withLock { $0[pid] } } }
}
private final class LockedBool: Sendable {
    private let stored: OSAllocatedUnfairLock<Bool>
    init(_ value: Bool) { stored = OSAllocatedUnfairLock(initialState: value) }
    var value: Bool {
        get { stored.withLock { $0 } }
        set { stored.withLock { $0 = newValue } }
    }
}
private final class LockedArray: Sendable {
    private let stored = OSAllocatedUnfairLock<[Int]>(initialState: [])
    func append(_ value: Int) { stored.withLock { $0.append(value) } }
    var values: [Int] { stored.withLock { $0 } }
}
