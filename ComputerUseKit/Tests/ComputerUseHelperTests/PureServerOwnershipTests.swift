import ComputerUseCore
import Foundation
import os
import XCTest

@testable import ComputerUseHelper

// FAKE ONLY. Construction is passive (a read of the pause flag); never start a
// server, connect a socket, execute a tool, call DisplayAwake, or use a real
// process provider. admit/finish are the production bookkeeping path before and
// after power/tool execution, not a test-only bypass flag.
private final class ServerJournal: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [String]())
    func append(_ event: String) { state.withLock { $0.append(event) } }
    var events: [String] { state.withLock { $0 } }
}

private final class ServerReference: Sendable {
    private struct State: Sendable { weak var server: HelperServer? }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var server: HelperServer? { state.withLock { $0.server } }
    func install(_ server: HelperServer) { state.withLock { $0.server = server } }
}

private final class ServerExecutor: ToolExecutor {
    let cancelHook: @Sendable (Set<String>) -> Void
    let shutdownHook: @Sendable () -> Void
    let exitHook: @Sendable (AgentSession) -> Void
    init(cancel: @escaping @Sendable (Set<String>) -> Void = { _ in },
         shutdown: @escaping @Sendable () -> Void = {},
         exited: @escaping @Sendable (AgentSession) -> Void = { _ in }) {
        cancelHook = cancel
        shutdownHook = shutdown
        exitHook = exited
    }
    func execute(_ call: ToolCallRequest) throws -> ToolOutcome {
        XCTFail("Pure server fixture must never execute tools")
        throw Errors.make("helper_stopped")
    }
    func cancel(agentKeys: Set<String>) { cancelHook(agentKeys) }
    func shutdown() { shutdownHook() }
    func agentExited(_ agent: AgentSession, withAppQueue: (String, () throws -> ToolOutcome) throws -> ToolOutcome) {
        exitHook(agent)
    }
}

private final class ServerRetirement: Sendable {
    let retired: @Sendable () -> Void
    init(_ retired: @escaping @Sendable () -> Void) { self.retired = retired }
    deinit { retired() }
}

private struct PureServerFixture: Sendable {
    let folder: URL
    let sessions: Sessions
    let server: HelperServer
    init(executor: ServerExecutor = ServerExecutor(),
         process: @escaping Sessions.ProcessProvider = { _ in nil },
         configure: (inout HelperConfiguration) -> Void = { _ in }) {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("pure-server-\(UUID().uuidString)")
        sessions = Sessions(process: process)
        var configuration = HelperConfiguration(
            environment: ["TERM_LLM_COMPUTER_HOME": folder.path,
                          "TERM_LLM_COMPUTER_SOCKET": folder.appendingPathComponent("unused.sock").path],
            grants: { ["fake": true] }, allow: { _ in XCTFail("No permission requests in pure fixtures") })
        configure(&configuration)
        server = HelperServer(executor: executor, configuration: configuration, sessions: sessions)
    }
    func admit(_ key: String) throws -> HelperServer.Admission {
        try server.admit(peerPID: 123, environment: ["TERM_LLM_SESSION_ID": key])
    }
    func assertPassive(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path),
                       "No listener, lock, pause or log files may be created", file: file, line: line)
    }
}

final class PureServerOwnershipTests: XCTestCase {
    func testConfigurationIsCheckedSendableAndFrozenAtConstruction() throws {
        func checked<T: Sendable>(_ value: T) {}
        let log = ServerJournal()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pure-server-\(UUID().uuidString)")
        var builder = HelperConfiguration(environment: ["TERM_LLM_COMPUTER_HOME": folder.path], grants: { ["old": true] })
        builder.onWorking = { log.append("old:\($0)") }
        let server = HelperServer(executor: ServerExecutor(), configuration: builder, sessions: Sessions(process: { _ in nil }))
        checked(builder)
        checked(server)
        builder.grants = { ["new": true] }
        builder.onWorking = { log.append("new:\($0)") }
        builder.environment["TERM_LLM_COMPUTER_HOME"] = "/not-used"
        XCTAssertEqual(server.status["grants"] as? [String: Bool], ["old": true])
        XCTAssertEqual(server.configuration.environment["TERM_LLM_COMPUTER_HOME"], folder.path)
        let call = try server.admit(peerPID: 1, environment: ["TERM_LLM_SESSION_ID": "one"])
        server.finish(call, remember: false)
        server.stop()
        XCTAssertEqual(log.events, ["old:true", "old:false"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testGrantsMayReenterStatusBookkeepingAndStop() {
        let reference = ServerReference(), log = ServerJournal()
        let fixture = PureServerFixture(executor: ServerExecutor(cancel: { keys in
            XCTAssertTrue(keys.isEmpty)
            XCTAssertFalse(reference.server?.hasRunningCalls ?? true)
            log.append("cancel")
        }), configure: { configuration in
            configuration.grants = {
                XCTAssertFalse(reference.server?.hasRunningCalls ?? true)
                reference.server?.stopCurrentTurn()
                return ["fake": true]
            }
        })
        reference.install(fixture.server)
        XCTAssertEqual(fixture.server.status["grants"] as? [String: Bool], ["fake": true])
        XCTAssertEqual(log.events, ["cancel"])
        fixture.server.stop()
        fixture.assertPassive()
    }

    func testWorkingAndCancelMayReenterStatusAndStopWithNonemptyKeys() throws {
        let reference = ServerReference(), log = ServerJournal()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let fixture = PureServerFixture(executor: ServerExecutor(cancel: { keys in
            guard let server = reference.server else { return XCTFail("Missing server") }
            if keys.isEmpty {
                XCTAssertFalse(server.hasRunningCalls)
                return
            }
            XCTAssertEqual(keys, ["one"])
            let agent = server.sessions.agent(peerPID: 1, env: ["TERM_LLM_SESSION_ID": "one"])
            XCTAssertTrue(server.sessions.isStopped(agent), "Publish Sessions.stop BEFORE executor.cancel")
            XCTAssertEqual(server.status["running"] as? Int, 1)
            let first = calls.withLock { $0 += 1; return $0 == 1 }
            if first { server.stopCurrentTurn() }
            log.append("cancel")
        }), configure: { configuration in
            configuration.onWorking = { working in
                guard let server = reference.server else { return XCTFail("Missing server") }
                log.append("working:\(working)")
                XCTAssertEqual(server.status["running"] as? Int, working ? 1 : 0)
                if working { server.stopCurrentTurn() }
            }
        })
        reference.install(fixture.server)
        let call = try fixture.admit("one")
        XCTAssertEqual(log.events, ["working:true", "cancel", "cancel"])
        fixture.server.finish(call, remember: false)
        XCTAssertEqual(log.events.last, "working:false")
        fixture.server.stop()
        fixture.assertPassive()
    }

    func testWorkingHandoffPreservesOrderWhileFirstEffectIsBlocked() throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0), log = ServerJournal()
        let effects = OSAllocatedUnfairLock(initialState: 0)
        let fixture = PureServerFixture(configure: { configuration in
            configuration.onWorking = { working in
                log.append("\(working)")
                let first = effects.withLock { $0 += 1; return $0 == 1 }
                if first {
                    entered.signal()
                    XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                }
            }
        })
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                let first = try fixture.admit("first")
                fixture.server.finish(first, remember: false)
            } catch { XCTFail("Unexpected admission failure: \(error)") }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        let second = try fixture.admit("second")
        XCTAssertEqual(fixture.server.status["running"] as? Int, 2)
        fixture.server.finish(second, remember: false)
        XCTAssertEqual(log.events, ["true"], "Only the ordered drainer may invoke callbacks")
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(log.events, ["true", "true", "true", "false"])
        fixture.server.stop()
        fixture.assertPassive()
    }

    func testWorkingHandoffSupportsNestedAdmissionWithoutReorderingFalse() throws {
        let reference = ServerReference(), log = ServerJournal()
        let count = OSAllocatedUnfairLock(initialState: 0)
        let fixture = PureServerFixture(configure: { configuration in
            configuration.onWorking = { working in
                log.append("\(working)")
                let first = count.withLock { $0 += 1; return $0 == 1 }
                if first, let server = reference.server {
                    do {
                        let nested = try server.admit(peerPID: 1, environment: ["TERM_LLM_SESSION_ID": "nested"])
                        server.finish(nested, remember: false)
                    } catch { XCTFail("Unexpected nested admission failure: \(error)") }
                }
            }
        })
        reference.install(fixture.server)
        let outer = try fixture.admit("outer")
        fixture.server.finish(outer, remember: false)
        XCTAssertEqual(log.events, ["true", "true", "true", "false"])
        fixture.server.stop()
        fixture.assertPassive()
    }

    func testStopSelectsActiveAndRecentKeysAndPublishesSessionsFirst() throws {
        let reference = ServerReference(), log = ServerJournal()
        let fixture = PureServerFixture(executor: ServerExecutor(cancel: { keys in
            guard let server = reference.server else { return XCTFail("Missing server") }
            XCTAssertEqual(keys, ["active", "recent"])
            for key in keys {
                let agent = server.sessions.agent(peerPID: 1, env: ["TERM_LLM_SESSION_ID": key])
                XCTAssertTrue(server.sessions.isStopped(agent))
            }
            log.append("cancel")
        }, shutdown: { log.append("shutdown") }))
        reference.install(fixture.server)
        let recent = try fixture.admit("recent")
        fixture.server.finish(recent, remember: true)
        let active = try fixture.admit("active")
        fixture.server.stopCurrentTurn()
        fixture.server.finish(active, remember: true)
        fixture.server.stop()
        XCTAssertEqual(log.events, ["cancel", "cancel", "shutdown"])
        fixture.assertPassive()
    }

    func testStopDuringBlockedProcessSamplingStaysResponsiveAndRejectsLateAdmission() {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0), log = ServerJournal()
        let fixture = PureServerFixture(process: { _ in
            entered.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return nil
        }, configure: { $0.onWorking = { log.append("\($0)") } })
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                let late = try fixture.admit("blocked")
                fixture.server.finish(late, remember: false)
                XCTFail("Stop must invalidate an in-flight admission")
            } catch let error as HarnessError { XCTAssertEqual(error.name, "stopped_by_user") }
            catch { XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(fixture.server.status["running"] as? Int, 0)
        fixture.server.stopCurrentTurn()
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(log.events.isEmpty)
        fixture.server.stop()
        fixture.assertPassive()
    }

    func testShutdownDuringBlockedSamplingCannotEnrollAfterExecutorShutdown() {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0), log = ServerJournal()
        let fixture = PureServerFixture(executor: ServerExecutor(shutdown: { log.append("shutdown") }), process: { _ in
            entered.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return nil
        }, configure: { $0.onWorking = { log.append("working:\($0)") } })
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                let late = try fixture.admit("blocked")
                fixture.server.finish(late, remember: false)
                XCTFail("No enrollment after shutdown")
            } catch let refusal as HelperServer.AdmissionRefusal {
                XCTAssertEqual(refusal, .stopping)
                let reply = refusal.wireReply(id: "blocked")
                XCTAssertEqual((reply["error"] as? [String: Any])?["errorName"] as? String, "stopping")
                XCTAssertNil(reply["result"])
            } catch { XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        fixture.server.stop()
        XCTAssertEqual(log.events, ["shutdown"])
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(log.events, ["shutdown"])
        fixture.assertPassive()
    }

    func testShutdownDrainsAdmittedBookkeepingBeforeExecutorAndCallback() throws {
        let cancelled = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let reference = ServerReference(), log = ServerJournal()
        let fixture = PureServerFixture(executor: ServerExecutor(cancel: { keys in
            XCTAssertEqual(keys, ["active"])
            XCTAssertEqual(reference.server?.status["running"] as? Int, 1)
            cancelled.signal()
        }, shutdown: {
            XCTAssertFalse(reference.server?.hasRunningCalls ?? true)
            log.append("shutdown")
        }), configure: { $0.onWorking = { log.append("working:\($0)") } })
        reference.install(fixture.server)
        fixture.server.onShutdown = {
            XCTAssertTrue(fixture.server.isStopping)
            log.append("callback")
            fixture.server.stop() // finished already: reentrant and not self-joining
        }
        let active = try fixture.admit("active")
        DispatchQueue.global().async { fixture.server.stop(); done.signal() }
        XCTAssertEqual(cancelled.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(fixture.server.status["running"] as? Int, 1)
        XCTAssertEqual(log.events, ["working:true"])
        fixture.server.finish(active, remember: false)
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(log.events, ["working:true", "working:false", "shutdown", "callback"])
        fixture.assertPassive()
    }


    func testShutdownDrainsReapingAndPreventsLaterCleanup() throws {
        let sampling = OSAllocatedUnfairLock(initialState: false)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let cancelled = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let reaped = DispatchSemaphore(value: 0), log = ServerJournal()
        let fixture = PureServerFixture(executor: ServerExecutor(cancel: { keys in
            XCTAssertTrue(keys.isEmpty)
            cancelled.signal()
        }, shutdown: { log.append("shutdown") }, exited: { agent in
            XCTAssertTrue(agent.exited)
            log.append("exited")
        }), process: { pid in
            if pid == 1 { return ProcessIdentity(pid: 1, parent: 2, path: "/fake/client", started: 1) }
            guard pid == 2 else { return nil }
            if sampling.withLock({ $0 }) {
                entered.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                return nil
            }
            return ProcessIdentity(pid: 2, parent: 0, path: "/fake/agent", started: 1)
        })
        let call = try fixture.server.admit(peerPID: 1, environment: [:])
        fixture.server.finish(call, remember: false)
        sampling.withLock { $0 = true }
        DispatchQueue.global().async { fixture.server.reapSessions(); reaped.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        DispatchQueue.global().async { fixture.server.stop(); done.signal() }
        XCTAssertEqual(cancelled.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(fixture.server.status["running"] as? Int, 0)
        XCTAssertTrue(log.events.isEmpty, "Executor shutdown must wait for enrolled reaping")
        release.signal()
        XCTAssertEqual(reaped.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(log.events, ["exited", "shutdown"])
        fixture.server.reapSessions()
        XCTAssertEqual(log.events, ["exited", "shutdown"])
        fixture.assertPassive()
    }

    func testConcurrentShutdownIsOneShotAndCallbackCanReenter() {
        let reference = ServerReference(), log = ServerJournal()
        let fixture = PureServerFixture(executor: ServerExecutor(shutdown: {
            XCTAssertTrue(reference.server?.isStopping ?? false)
            log.append("shutdown")
        }))
        reference.install(fixture.server)
        fixture.server.onShutdown = {
            log.append("callback")
            XCTAssertEqual(reference.server?.status["running"] as? Int, 0)
            reference.server?.stopCurrentTurn()
            reference.server?.stop()
        }
        DispatchQueue.concurrentPerform(iterations: 12) { _ in fixture.server.stop() }
        XCTAssertEqual(log.events, ["shutdown", "callback"])
        fixture.server.onShutdown = { XCTFail("Late callback must not be invoked") }
        XCTAssertNil(fixture.server.onShutdown)
        fixture.server.stop()
        fixture.assertPassive()
    }

    func testReplacedAndInvokedShutdownClosureGraphsRetireOutsideLocks() {
        let reference = ServerReference(), log = ServerJournal()
        let fixture = PureServerFixture()
        reference.install(fixture.server)
        func install(_ name: String) {
            let captured = ServerRetirement {
                let reentered = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    XCTAssertEqual(reference.server?.status["running"] as? Int, 0)
                    reference.server?.stopCurrentTurn()
                    reentered.signal()
                }
                XCTAssertEqual(reentered.wait(timeout: .now() + 5), .success,
                               "Captured graph retired under the bookkeeping lock")
                log.append("retired:\(name)")
            }
            fixture.server.onShutdown = { [captured] in
                withExtendedLifetime(captured) {}
                log.append("invoked:\(name)")
            }
        }
        install("old")
        install("new")
        XCTAssertEqual(log.events, ["retired:old"])
        fixture.server.stop()
        XCTAssertEqual(log.events, ["retired:old", "invoked:new", "retired:new"])
        fixture.assertPassive()
    }

    func testDirectStopInWorkingCallbackQueuesShutdownInsteadOfJoiningItself() throws {
        let reference = ServerReference(), done = DispatchSemaphore(value: 0)
        let fixture = PureServerFixture(configure: { configuration in
            configuration.onWorking = { working in
                if working { reference.server?.stop() }
            }
        })
        reference.install(fixture.server)
        fixture.server.onShutdown = { done.signal() }
        let call = try fixture.admit("one")
        fixture.server.finish(call, remember: false)
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        fixture.server.stop()
        fixture.assertPassive()
    }

    func testNoEffectsShutdownRefusalMapsToRetryableWireErrorBeforeSampling() {
        let fixture = PureServerFixture(process: { _ in
            XCTFail("A closed admission must not sample processes")
            return nil
        })
        fixture.server.stop()
        for name in ["click", "help", "skill", "turn-started", "turn-ended"] {
            do {
                let call = try fixture.server.admit(peerPID: 1, environment: [:], kind: .init(name: name))
                fixture.server.finish(call, remember: false)
                XCTFail("Shutdown must refuse every kind of admission")
            } catch let refusal as HelperServer.AdmissionRefusal {
                XCTAssertEqual(refusal, .stopping)
                let reply = refusal.wireReply(id: name)
                XCTAssertEqual(reply["id"] as? String, name)
                XCTAssertEqual(reply["jsonrpc"] as? String, "2.0")
                XCTAssertEqual((reply["error"] as? [String: Any])?["errorName"] as? String, "stopping")
                XCTAssertNil(reply["result"])
            } catch { XCTFail("Unexpected error: \(error)") }
        }
        // Cancellation after admission is still an ordinary, non-retryable
        // failure result, using the same pure primitives as answerOnWorker.
        let cancelled = ToolOutcome.failure(Errors.make("helper_stopped"), json: false)
        let reply = Wire.reply(id: "running", exit: cancelled.exit, stdout: cancelled.stdout, stderr: cancelled.stderr)
        XCTAssertNil(reply["error"])
        XCTAssertEqual((reply["result"] as? [String: Any])?["exit"] as? Int, 1)
        fixture.assertPassive()
    }

    func testLifecycleAdmissionSurvivesStopDuringSamplingAndNewTurnResetsLiveAgent() throws {
        for name in ["help", "skill", "turn-started", "turn-ended"] {
            let sampling = OSAllocatedUnfairLock(initialState: false)
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let done = DispatchSemaphore(value: 0)
            let fixture = PureServerFixture(process: { _ in
                if sampling.withLock({ $0 }) {
                    entered.signal()
                    XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                }
                return nil
            })
            let previous = try fixture.admit("same")
            let agent = previous.agent
            agent.ended = true
            agent.denied = ["/fake/Denied.app"]
            agent.instructed = ["fake.instructed"]
            fixture.server.finish(previous, remember: true)
            sampling.withLock { $0 = true }
            let kind = HelperServer.AdmissionKind(name: name)
            XCTAssertEqual(kind, .lifecycle)
            DispatchQueue.global().async {
                defer { done.signal() }
                do {
                    let call = try fixture.server.admit(
                        peerPID: 1, environment: ["TERM_LLM_SESSION_ID": "same"], kind: kind)
                    defer { fixture.server.finish(call, remember: false) }
                    XCTAssertTrue(call.agent === agent, "Reuse the live session, not a replacement")
                    XCTAssertFalse(agent.exited)
                    XCTAssertTrue(fixture.sessions.isStopped(agent))
                    if name == "turn-started" {
                        // Exercise the real pure lifecycle operation without
                        // entering answer/tool/DisplayAwake execution paths.
                        fixture.sessions.turnStarted(call.agent)
                        XCTAssertFalse(agent.ended)
                        XCTAssertTrue(agent.signalsTurns)
                        XCTAssertTrue(agent.denied.isEmpty)
                        XCTAssertTrue(agent.instructed.isEmpty)
                        XCTAssertFalse(fixture.sessions.isStopped(agent))
                    } else {
                        XCTAssertTrue(agent.ended)
                        XCTAssertEqual(agent.denied, ["/fake/Denied.app"])
                        XCTAssertEqual(agent.instructed, ["fake.instructed"])
                    }
                } catch { XCTFail("Lifecycle \(name) must survive Stop during sampling: \(error)") }
            }
            XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
            fixture.server.stopCurrentTurn()
            XCTAssertTrue(fixture.sessions.isStopped(agent))
            XCTAssertEqual(agent.cancels, 1)
            release.signal()
            XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
            XCTAssertFalse(fixture.server.hasRunningCalls)
            fixture.server.stop()
            fixture.assertPassive()
        }
        XCTAssertEqual(HelperServer.AdmissionKind(name: "click"), .ordinary)
    }

    func testLifecycleAdmissionNeverBypassesShutdownDuringSampling() {
        for name in ["help", "skill", "turn-started", "turn-ended"] {
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let done = DispatchSemaphore(value: 0), log = ServerJournal()
            let fixture = PureServerFixture(process: { _ in
                entered.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                return nil
            }, configure: { $0.onWorking = { log.append("working:\($0)") } })
            DispatchQueue.global().async {
                defer { done.signal() }
                do {
                    let call = try fixture.server.admit(peerPID: 1, environment: [:], kind: .init(name: name))
                    fixture.server.finish(call, remember: false)
                    XCTFail("Lifecycle must not bypass shutdown")
                } catch let refusal as HelperServer.AdmissionRefusal {
                    XCTAssertEqual(refusal, .stopping)
                    XCTAssertEqual((refusal.wireReply(id: name)["error"] as? [String: Any])?["errorName"] as? String,
                                   "stopping")
                } catch { XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
            fixture.server.stop()
            release.signal()
            XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
            XCTAssertTrue(log.events.isEmpty)
            fixture.assertPassive()
        }
    }

    func testDirectStopFromCancelControlCallbackDoesNotJoinItsOwnEnrollment() {
        let reference = ServerReference(), done = DispatchSemaphore(value: 0)
        let log = ServerJournal(), cancellations = OSAllocatedUnfairLock(initialState: 0)
        let fixture = PureServerFixture(executor: ServerExecutor(cancel: { keys in
            XCTAssertTrue(keys.isEmpty)
            log.append("cancel")
            let first = cancellations.withLock { $0 += 1; return $0 == 1 }
            if first { reference.server?.stop() }
        }, shutdown: { log.append("shutdown") }))
        reference.install(fixture.server)
        fixture.server.onShutdown = { done.signal() }
        // A control-only answer never admits a tool or enters the power path.
        let reply = fixture.server.answer(["id": "stop", "jsonrpc": "2.0", "method": "stop"],
                                          peerPID: 1, peerUID: getuid())
        XCTAssertNil(reply["error"])
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        fixture.server.stop()
        XCTAssertEqual(log.events, ["cancel", "cancel", "shutdown"])
        fixture.assertPassive()
    }

    func testDirectStopFromShutdownCallbackDoesNotJoinItsOwnShutdown() {
        let reference = ServerReference(), log = ServerJournal()
        let fixture = PureServerFixture(executor: ServerExecutor(shutdown: {
            log.append("shutdown")
            XCTAssertTrue(reference.server?.isStopping ?? false)
            reference.server?.stop()
        }))
        reference.install(fixture.server)
        fixture.server.onShutdown = { log.append("finished") }
        fixture.server.stop()
        fixture.server.stop()
        XCTAssertEqual(log.events, ["shutdown", "finished"])
        fixture.assertPassive()
    }

    func testDirectStopFromReapingCallbackQueuesUntilReapingReturns() throws {
        let alive = OSAllocatedUnfairLock(initialState: true)
        let reference = ServerReference(), done = DispatchSemaphore(value: 0), log = ServerJournal()
        let fixture = PureServerFixture(executor: ServerExecutor(shutdown: { log.append("shutdown") }, exited: { agent in
            XCTAssertTrue(agent.exited)
            XCTAssertFalse(reference.server?.hasRunningCalls ?? true)
            log.append("exited")
            reference.server?.stop()
        }), process: { pid in
            if pid == 1 { return ProcessIdentity(pid: 1, parent: 2, path: "/fake/client", started: 1) }
            guard pid == 2, alive.withLock({ $0 }) else { return nil }
            return ProcessIdentity(pid: 2, parent: 0, path: "/fake/agent", started: 1)
        })
        reference.install(fixture.server)
        fixture.server.onShutdown = { done.signal() }
        let call = try fixture.server.admit(peerPID: 1, environment: [:])
        fixture.server.finish(call, remember: false)
        alive.withLock { $0 = false }
        fixture.server.reapSessions()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        fixture.server.stop()
        XCTAssertEqual(log.events, ["exited", "shutdown"])
        fixture.assertPassive()
    }

    func testDirectStopFromFakeAllowControlCallbackDoesNotJoinItsOwnRequest() {
        let reference = ServerReference(), done = DispatchSemaphore(value: 0)
        let fixture = PureServerFixture(configure: { configuration in
            configuration.allow = { name in
                XCTAssertEqual(name, "fake")
                reference.server?.stop()
            }
        })
        reference.install(fixture.server)
        fixture.server.onShutdown = { done.signal() }
        let reply = fixture.server.answer(
            ["id": "allow", "jsonrpc": "2.0", "method": "allow", "params": ["grant": "fake"]],
            peerPID: 1, peerUID: getuid())
        XCTAssertNil(reply["error"])
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        fixture.server.stop()
        fixture.assertPassive()
    }

}
