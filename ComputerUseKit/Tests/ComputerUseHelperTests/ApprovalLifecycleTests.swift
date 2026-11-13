import ComputerUseCore
import ComputerUseSystem
import Foundation
import XCTest
import os

@testable import ComputerUseHelper
@testable import ComputerUseSystem

// Standalone, fake-only lifecycle coverage. Never start/answer/stop a server or
// execute a socket tool: those paths can take DisplayAwake/input assertions.
// HelperServer construction is passive (private-path stat only). Harness lifecycle
// calls have no app sessions; fail-fast FIFO seams prevent any app cleanup work.
private final class LifecycleApprovals: Sendable {
    let panel = AskQueue()
    let approvals: Approvals
    let store: ApprovalStore
    init(folder: URL, sleep: @escaping @Sendable (Double) -> Void = { _ in XCTFail("Unexpected wait") }) {
        let panel = panel
        store = ApprovalStore(directory: folder)
        approvals = Approvals(
            store: store, ask: { panel.append($0); return true },
            withdraw: { panel.withdraw(title: $0) }, now: { 0 }, sleep: sleep,
            alive: { _ in true })
    }
}

private func lifecycleExecutor(_ approvals: Approvals) -> HarnessExecutor {
    // Dependencies' constructors only store closures/paths; no production hook is
    // invoked. Replace both adapters actually used by letGo, before execution.
    var dependencies = HarnessExecutor.Dependencies()
    dependencies.approvals = approvals
    dependencies.presence = Presence(
        enabled: { false }, now: { XCTFail("Unexpected presence clock"); return 0 },
        send: { _ in XCTFail("No overlay") }, schedule: { _ in XCTFail("No UI scheduling") },
        ask: { _ in XCTFail("No real panel") }, withdraw: { _ in XCTFail("No real panel") })
    let system = Person.System(
        now: { XCTFail("Unexpected person clock"); return 0 },
        sleep: { _ in XCTFail("Unexpected person wait") },
        frontmostPID: { XCTFail("No frontmost query"); return 0 },
        bundleOf: { _ in XCTFail("No process query"); return "" },
        hidIdle: { _ in XCTFail("No input query"); return 0 },
        secureInputPID: { XCTFail("No input query"); return nil },
        windowPID: { _ in XCTFail("No window query"); return 0 },
        canListen: { XCTFail("No permission query"); return false })
    let hooks = Person.Hooks(
        pointerActivity: { _ in XCTFail("No overlay") },
        shownMenu: { _ in XCTFail("No AX query"); return nil },
        post: { _, _ in XCTFail("No input posting") },
        later: { _, _ in XCTFail("No scheduled input") })
    let watch = Person.Watch(
        isRunning: { false }, schedule: { _ in XCTFail("No tap scheduling") },
        create: { _ in XCTFail("No tap creation"); return nil })
    dependencies.person = Person(system: system, hooks: hooks, watch: watch)
    return HarnessExecutor(dependencies: dependencies)
}

private func lifecycleCall(_ name: String, agent: AgentSession, sessions: Sessions, cancel: Bool = false) -> ToolCallRequest {
    ToolCallRequest(
        name: name, arguments: ["cancel": cancel], stdin: nil, environment: [:],
        agent: agent, sessions: sessions, cwd: "/", deadline: Date().addingTimeInterval(5),
        abandoned: { false }, withAppQueue: { _, _ in
            XCTFail("Lifecycle fixture has no app resources: no AX/input/cleanup may run")
            throw Errors.make("request_timed_out")
        })
}

private final class StopProbeExecutor: ToolExecutor {
    private let cancellation = HelperFixtureBox<@Sendable (Set<String>) -> Void>({ _ in
        XCTFail("Unexpected cancellation")
    })
    var onCancel: @Sendable (Set<String>) -> Void {
        get { cancellation.value }
        set { cancellation.value = newValue }
    }
    func execute(_ call: ToolCallRequest) throws -> ToolOutcome {
        XCTFail("No tool execution or display-awake assertion allowed")
        throw Errors.make("request_timed_out")
    }
    func cancel(agentKeys: Set<String>) {
        let callback = onCancel
        callback(agentKeys)
    }
}

final class ApprovalLifecycleTests: XCTestCase {
    private var folder: URL!
    private let target = AppTarget(path: "/fake/Demo.app", bundleID: "test.demo", name: "Demo")
    private let policy = PolicyDecision(decision: .allowed, risk: .low, allowPersistent: true, warning: nil)
    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }
    private func pending(_ fixture: LifecycleApprovals, agent: AgentSession) {
        XCTAssertThrowsError(try fixture.approvals.ensure(
            agent: agent, target: target, policy: policy, deadline: 0)) {
            XCTAssertEqual(($0 as? HarnessError)?.name, Errors.make("approval_pending").name)
        }
    }
    func testNormalTurnEndKeepsInFlightApprovalWaitLiveAndAnswerable() throws {
        let waiting = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let fixture = LifecycleApprovals(folder: folder, sleep: { _ in
            waiting.signal()
            XCTAssertEqual(resume.wait(timeout: .now() + 5), .success)
        })
        let executor = lifecycleExecutor(fixture.approvals)
        let sessions = Sessions(process: { _ in nil }), agent = AgentSession(key: "agent")
        sessions.turnStarted(agent)
        let target = target, policy = policy
        DispatchQueue.global().async {
            defer { finished.signal() }
            do { try fixture.approvals.ensure(agent: agent, target: target, policy: policy, deadline: 100) }
            catch { XCTFail("Normal turn end must not cancel approval wait: \(error)") }
        }
        XCTAssertEqual(waiting.wait(timeout: .now() + 5), .success)
        defer { resume.signal() }
        let question = try XCTUnwrap(fixture.panel.asks.first)
        _ = try executor.execute(lifecycleCall("turn-ended", agent: agent, sessions: sessions))
        XCTAssertFalse(agent.ended)
        XCTAssertEqual(agent.cancels, 0)
        XCTAssertEqual(fixture.panel.asks.count, 1)
        XCTAssertTrue(fixture.panel.asks.first === question)
        XCTAssertEqual(finished.wait(timeout: .now() + 0.05), .timedOut)
        fixture.panel.answer(question, choice: Approvals.session)
        resume.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(fixture.approvals.approved(agent: agent, bundleID: target.bundleID, policy: policy))
        XCTAssertEqual(fixture.approvals.generationCount, 0)
    }
    func testNormalTurnEndKeepsAlreadyPendingQuestionAnswerable() throws {
        let fixture = LifecycleApprovals(folder: folder)
        let executor = lifecycleExecutor(fixture.approvals)
        let sessions = Sessions(process: { _ in nil }), agent = AgentSession(key: "agent")
        sessions.turnStarted(agent)
        pending(fixture, agent: agent)
        let question = try XCTUnwrap(fixture.panel.asks.first)
        agent.denied.insert("other-path")
        _ = try executor.execute(lifecycleCall("turn-ended", agent: agent, sessions: sessions))
        XCTAssertTrue(agent.denied.isEmpty)
        XCTAssertFalse(agent.ended)
        XCTAssertEqual(agent.cancels, 0)
        XCTAssertTrue(fixture.panel.asks.first === question)
        fixture.panel.answer(question, choice: Approvals.session)
        try fixture.approvals.ensure(agent: agent, target: target, policy: policy, deadline: 0)
        XCTAssertEqual(fixture.approvals.generationCount, 0)
    }
    func testCancellingTurnEndWithdrawsPendingQuestionWithOrWithoutTurnSignals() throws {
        for signals in [false, true] {
            let fixture = LifecycleApprovals(folder: folder)
            let executor = lifecycleExecutor(fixture.approvals)
            let sessions = Sessions(process: { _ in nil }), agent = AgentSession(key: "agent-\(signals)")
            if signals { sessions.turnStarted(agent) }
            pending(fixture, agent: agent)
            let old = try XCTUnwrap(fixture.panel.asks.first)
            _ = try executor.execute(lifecycleCall("turn-ended", agent: agent, sessions: sessions, cancel: true))
            XCTAssertEqual(agent.cancels, 1)
            XCTAssertEqual(agent.ended, signals)
            XCTAssertTrue(fixture.panel.asks.isEmpty)
            XCTAssertEqual(fixture.approvals.generationCount, 0)
            old.onAnswer(Approvals.always)
            XCTAssertFalse(fixture.approvals.approved(agent: agent, bundleID: target.bundleID, policy: policy))
            XCTAssertTrue(fixture.store.always().isEmpty)
        }
    }
    func testNewTurnInvalidatesOldPendingQuestion() throws {
        let fixture = LifecycleApprovals(folder: folder)
        let executor = lifecycleExecutor(fixture.approvals)
        let sessions = Sessions(process: { _ in nil }), agent = AgentSession(key: "agent")
        pending(fixture, agent: agent)
        let old = try XCTUnwrap(fixture.panel.asks.first)
        _ = try executor.execute(lifecycleCall("turn-started", agent: agent, sessions: sessions))
        XCTAssertTrue(agent.signalsTurns)
        XCTAssertTrue(fixture.panel.asks.isEmpty)
        XCTAssertEqual(fixture.approvals.generationCount, 0)
        pending(fixture, agent: agent)
        let fresh = try XCTUnwrap(fixture.panel.asks.first)
        XCTAssertFalse(old === fresh)
        old.onAnswer(Approvals.session)
        XCTAssertFalse(fixture.approvals.approved(agent: agent, bundleID: target.bundleID, policy: policy))
        fixture.panel.answer(fresh, choice: Approvals.session)
        XCTAssertTrue(fixture.approvals.approved(agent: agent, bundleID: target.bundleID, policy: policy))
    }
    func testStopHookWithdrawsAlreadyPendingQuestionOnlyForSelectedKeys() throws {
        let fixture = LifecycleApprovals(folder: folder)
        let executor = lifecycleExecutor(fixture.approvals)
        let sessions = Sessions(process: { _ in nil })
        let agent = sessions.agent(peerPID: 1, env: ["TERM_LLM_SESSION_ID": "first"])
        let other = sessions.agent(peerPID: 1, env: ["TERM_LLM_SESSION_ID": "other"])
        pending(fixture, agent: agent)
        pending(fixture, agent: other)
        let old = fixture.panel.asks[0], live = fixture.panel.asks[1]
        sessions.stop([agent.key])
        executor.cancel(agentKeys: [agent.key])
        XCTAssertEqual(agent.cancels, 1)
        XCTAssertTrue(sessions.isStopped(agent))
        XCTAssertEqual(fixture.panel.asks.count, 1)
        XCTAssertTrue(fixture.panel.asks[0] === live)
        old.onAnswer(Approvals.always)
        XCTAssertFalse(fixture.approvals.approved(agent: agent, bundleID: target.bundleID, policy: policy))
        fixture.panel.answer(live, choice: Approvals.session)
        XCTAssertTrue(fixture.approvals.approved(agent: other, bundleID: target.bundleID, policy: policy))
        XCTAssertEqual(fixture.approvals.generationCount, 0)
    }
    func testExitRetiresGenerationsAndNeverAskedLifecycleDoesNotAllocateThem() throws {
        let fixture = LifecycleApprovals(folder: folder)
        let executor = lifecycleExecutor(fixture.approvals)
        let sessions = Sessions(process: { _ in nil })
        for index in 0..<30 {
            let agent = AgentSession(key: "agent-\(index)")
            _ = try executor.execute(lifecycleCall("turn-started", agent: agent, sessions: sessions))
            _ = try executor.execute(lifecycleCall("turn-ended", agent: agent, sessions: sessions))
            XCTAssertEqual(fixture.approvals.generationCount, 0)
            pending(fixture, agent: agent)
            XCTAssertEqual(fixture.approvals.generationCount, 1)
            agent.exited = true
            executor.agentExited(agent, withAppQueue: { _, _ in
                XCTFail("No app cleanup in this pure fixture")
                throw Errors.make("request_timed_out")
            })
            XCTAssertTrue(fixture.panel.asks.isEmpty)
            XCTAssertEqual(fixture.approvals.generationCount, 0)
        }
    }
    func testServerStopCancellationHookCanReenterStopOutsideCondition() {
        let executor = StopProbeExecutor()
        let configuration = HelperConfiguration(
            environment: ["TERM_LLM_COMPUTER_HOME": folder.path,
                          "TERM_LLM_COMPUTER_SOCKET": folder.appendingPathComponent("unused.sock").path],
            grants: { [:] }, allow: { _ in XCTFail("No permission request") })
        let server = HelperServer(executor: executor, configuration: configuration, sessions: Sessions(process: { _ in nil }))
        let invocations = OSAllocatedUnfairLock<[Set<String>]>(initialState: [])
        executor.onCancel = { [weak server] keys in
            let first = invocations.withLock { calls in calls.append(keys); return calls.count == 1 }
            guard first, let server else { return }
            let reentered = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                XCTAssertFalse(server.hasRunningCalls)
                server.stopCurrentTurn()
                reentered.signal()
            }
            XCTAssertEqual(reentered.wait(timeout: .now() + 5), .success,
                           "Cancellation hook ran while HelperServer.condition was held")
        }
        server.stopCurrentTurn()
        XCTAssertEqual(invocations.withLock { $0 }, [[], []])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "Never start a listener or create helper state")
    }
}
