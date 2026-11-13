import ComputerUseCore
import Darwin
import Foundation
import os
import XCTest
@testable import ComputerUseHelper

// Pure registry tests. Every process lookup is injected; these tests never
// construct a server/executor or touch sockets, AX, input, UI, power or pasteboard.
private final class SessionProcesses: Sendable {
    typealias Hook = @Sendable (pid_t, ProcessIdentity?) -> ProcessIdentity?
    private struct State: Sendable {
        var records: [pid_t: ProcessIdentity]
        var hook: Hook?
    }
    private let state: OSAllocatedUnfairLock<State>
    init(_ records: [ProcessIdentity] = []) {
        state = OSAllocatedUnfairLock(initialState: State(records: Dictionary(uniqueKeysWithValues: records.map { ($0.pid, $0) })))
    }
    func set(_ record: ProcessIdentity) { state.withLock { $0.records[record.pid] = record } }
    func remove(_ pid: pid_t) { _ = state.withLock { $0.records.removeValue(forKey: pid) } }
    var hook: Hook? {
        get { state.withLock { $0.hook } }
        set { state.withLock { $0.hook = newValue } }
    }
    var lookup: Sessions.ProcessProvider {
        { [self] pid in
            let (record, hook) = state.withLock { ($0.records[pid], $0.hook) }
            if let hook { return hook(pid, record) }
            return record
        }
    }
}

private final class SessionLookupGate: Sendable {
    let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
    private let claimed = OSAllocatedUnfairLock(initialState: false)
    func claim() -> Bool {
        claimed.withLock { value in
            guard !value else { return false }
            value = true
            return true
        }
    }
    func block() {
        entered.signal()
        XCTAssertEqual(resume.wait(timeout: .now() + 5), .success, "Test did not release provider")
    }
}

private final class SessionReference: Sendable {
    private struct State: Sendable { weak var sessions: Sessions? }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var value: Sessions? {
        get { state.withLock { $0.sessions } }
        set { state.withLock { $0.sessions = newValue } }
    }
}

final class PureSessionsOwnershipTests: XCTestCase {
    private static func record(_ pid: pid_t, _ parent: pid_t, _ path: String, _ started: TimeInterval) -> ProcessIdentity {
        .init(pid: pid, parent: parent, path: path, started: started)
    }
    private static func processes() -> SessionProcesses {
        SessionProcesses([
            record(9, 8, "/fake/term-llm-computer", 1),
            record(8, 7, "/bin/-zsh", 2),
            record(7, 6, "/A.app/Contents/MacOS/term-llm", 3),
            record(6, 0, "/Host.app/Contents/MacOS/Host", 4),
        ])
    }
    private func wait(_ semaphore: DispatchSemaphore, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(semaphore.wait(timeout: .now() + 3), .success, file: file, line: line)
    }

    private static func addTree(_ table: SessionProcesses, host: pid_t) {
        table.set(record(host, 0, "/fake/agent", TimeInterval(host)))
        table.set(record(host + 1, host, "/bin/zsh", TimeInterval(host + 1)))
        table.set(record(host + 2, host + 1, "/fake/client", TimeInterval(host + 2)))
    }
    private func assertLookupOwnership(_ sessions: Sessions, active: Int, agents: Int, shells: Int,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let counts = sessions.lookupOwnershipCounts
        XCTAssertEqual(counts.active, active, file: file, line: line)
        XCTAssertEqual(counts.retiredAgents, agents, file: file, line: line)
        XCTAssertEqual(counts.retiredShells, shells, file: file, line: line)
    }
    private func parkedLookup(_ sessions: Sessions, table: SessionProcesses, peerPID: pid_t = 9,
                              env: [String: String] = [:], at pid: pid_t = 7, missingSample: Bool = false,
                              during: () -> Void) throws -> AgentSession {
        let gate = SessionLookupGate(), done = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock<AgentSession?>(initialState: nil)
        table.hook = { sampled, record in
            if sampled == pid, gate.claim() {
                gate.block()
                if missingSample { return nil }
            }
            return record
        }
        DispatchQueue.global().async {
            let agent = sessions.agent(peerPID: peerPID, env: env)
            result.withLock { $0 = agent }
            done.signal()
        }
        wait(gate.entered)
        defer { gate.resume.signal(); table.hook = nil }
        during()
        gate.resume.signal(); wait(done)
        return try XCTUnwrap(result.withLock { $0 })
    }

    func testIdentityAncestryWrappersHostBundlesAndEnvironmentUpdates() {
        let table = Self.processes(), sessions = Sessions(process: table.lookup)
        let parents = sessions.ancestry(of: 9)
        XCTAssertEqual(parents.map(\.pid), [8, 7, 6])
        XCTAssertTrue(sessions.callerAllowed(9))
        let agent = sessions.agent(peerPID: 9, env: ["old": "value"])
        XCTAssertEqual(agent.key, "7:3.0")
        XCTAssertEqual(agent.hosts, ["/A.app", "/Host.app"])
        XCTAssertEqual(agent.env, ["old": "value"])
        XCTAssertTrue(sessions.agent(peerPID: 9, env: ["new": "value"]) === agent)
        XCTAssertEqual(agent.env, ["new": "value"])
        // Host policy is established when the session is created, not unioned
        // with unrelated callers that later supply the same explicit ID.
        table.set(Self.record(6, 0, "/Changed.app/Contents/MacOS/Host", 4))
        XCTAssertTrue(sessions.agent(peerPID: 9, env: [:]) === agent)
        XCTAssertEqual(agent.hosts, ["/A.app", "/Host.app"])
        XCTAssertFalse(sessions.hostGone(agent))
        XCTAssertTrue(sessions.reap().isEmpty)
        XCTAssertNotEqual(Self.record(7, 6, "/agent", 3), Self.record(7, 6, "/agent", 3.000001))
    }

    func testOverridePrecedenceEmptyFallbackNoAgentAndExplicitSurvival() {
        let table = Self.processes(), sessions = Sessions(process: table.lookup)
        let primary = sessions.agent(peerPID: 9, env: ["TERM_LLM_SESSION_ID": "primary", "TERM_LLM_COMPUTER_SESSION": "fallback"])
        XCTAssertEqual(primary.key, "primary")
        XCTAssertEqual(primary.hosts, ["/A.app", "/Host.app"])
        XCTAssertEqual(sessions.agent(peerPID: 9, env: ["TERM_LLM_SESSION_ID": "", "TERM_LLM_COMPUTER_SESSION": "fallback"]).key, "fallback")
        XCTAssertEqual(sessions.agent(peerPID: 9, env: ["TERM_LLM_SESSION_ID": "", "TERM_LLM_COMPUTER_SESSION": ""]).key, "7:3.0")
        let unknown = sessions.agent(peerPID: 123, env: [:])
        XCTAssertEqual(unknown.key, "no-agent")
        XCTAssertTrue(unknown.hosts.isEmpty)
        XCTAssertTrue(sessions.agent(peerPID: 124, env: [:]) === unknown)
        table.remove(7)
        sessions.stop([primary.key, unknown.key])
        XCTAssertFalse(sessions.hostGone(primary))
        XCTAssertEqual(sessions.reap().map(\.key), ["7:3.0"])
        XCTAssertTrue(sessions.isStopped(primary))
        XCTAssertTrue(sessions.isStopped(unknown))
        XCTAssertTrue(sessions.agent(peerPID: 123, env: ["TERM_LLM_SESSION_ID": "primary"]) === primary)
    }

    func testAncestryCyclesAndAllWrappersTerminateWithoutChoosingPeer() {
        let table = SessionProcesses([Self.record(9, 8, "/peer.app/client", 1), Self.record(8, 7, "/bin/sh", 2), Self.record(7, 9, "/usr/bin/env", 3)])
        let sessions = Sessions(process: table.lookup)
        XCTAssertEqual(sessions.ancestry(of: 9).map(\.pid), [8, 7])
        let agent = sessions.agent(peerPID: 9, env: [:])
        XCTAssertEqual(agent.key, "no-agent")
        XCTAssertTrue(agent.hosts.isEmpty)
        XCTAssertFalse(sessions.callerAllowed(9))
    }

    func testPIDReuseReapsOnlyOldBirthAndClearsItsStopMark() {
        let table = Self.processes(), sessions = Sessions(process: table.lookup)
        let old = sessions.agent(peerPID: 9, env: [:])
        sessions.stop([old.key])
        table.set(Self.record(7, 6, "/A.app/Contents/MacOS/term-llm", 3.000001))
        XCTAssertTrue(sessions.hostGone(old))
        // The still-running wrapper must not adopt a reused PID as its host.
        XCTAssertTrue(sessions.agent(peerPID: 9, env: [:]).exited)
        XCTAssertEqual(sessions.reap().map(\.key), [old.key])
        XCTAssertTrue(old.exited)
        XCTAssertFalse(sessions.isStopped(old))
        // A new wrapper birth can establish a fresh host association.
        table.set(Self.record(8, 7, "/bin/-zsh", 2.000001))
        let fresh = sessions.agent(peerPID: 9, env: [:])
        XCTAssertEqual(fresh.key, "7:3.000001")
        XCTAssertFalse(fresh.exited)
        XCTAssertFalse(fresh === old)
        XCTAssertFalse(sessions.hostGone(fresh))
        XCTAssertTrue(sessions.reap().isEmpty)
    }

    func testOrphanWrapperRemembersDeadHostAfterReapButOverrideWins() {
        let table = Self.processes(), sessions = Sessions(process: table.lookup)
        let agent = sessions.agent(peerPID: 9, env: [:])
        table.remove(7)
        table.set(Self.record(8, 6, "/bin/-zsh", 2))
        XCTAssertTrue(sessions.hostGone(agent))
        XCTAssertEqual(sessions.reap().map(\.key), [agent.key])
        let orphan = sessions.agent(peerPID: 9, env: [:])
        XCTAssertTrue(orphan.exited)
        XCTAssertEqual(orphan.key, agent.key)
        let explicit = sessions.agent(peerPID: 9, env: ["TERM_LLM_SESSION_ID": "continued"])
        XCTAssertEqual(explicit.key, "continued")
        XCTAssertFalse(explicit.exited)
        // Reaping the wrapper itself permits a new shell identity/host.
        table.remove(8)
        XCTAssertTrue(sessions.reap().isEmpty)
        table.set(Self.record(8, 6, "/bin/-zsh", 5))
        XCTAssertEqual(sessions.agent(peerPID: 9, env: [:]).key, "6:4.0")
    }

    func testExplicitIDMatchingProcessKeyDoesNotAcquireProcessLifetime() {
        let table = Self.processes(), sessions = Sessions(process: table.lookup)
        let explicit = sessions.agent(peerPID: 9, env: ["TERM_LLM_SESSION_ID": "7:3.0"])
        XCTAssertTrue(sessions.agent(peerPID: 9, env: [:]) === explicit)
        table.remove(7)
        XCTAssertFalse(sessions.hostGone(explicit))
        XCTAssertTrue(sessions.reap().isEmpty)
    }

    func testStopTurnBoundariesAndLetGoSemantics() {
        let sessions = Sessions(process: { _ in nil })
        sessions.stop(["before"])
        let agent = sessions.agent(peerPID: 1, env: ["TERM_LLM_SESSION_ID": "before"])
        XCTAssertTrue(sessions.isStopped(agent))
        XCTAssertEqual(sessions.cancellationGeneration(agent), 0)
        sessions.letGo(agent, cancel: false)
        XCTAssertFalse(sessions.hasEnded(agent))
        sessions.letGo(agent, cancel: true)
        XCTAssertEqual(agent.cancels, 1)
        XCTAssertFalse(agent.ended, "Unsignalled turns do not become ended on let_go")
        agent.denied.insert("denied"); agent.instructed.insert("instructed")
        sessions.turnStarted(agent)
        XCTAssertTrue(agent.signalsTurns)
        XCTAssertFalse(sessions.isStopped(agent))
        XCTAssertTrue(agent.denied.isEmpty); XCTAssertTrue(agent.instructed.isEmpty)
        sessions.letGo(agent, cancel: false)
        XCTAssertFalse(agent.ended)
        sessions.letGo(agent, cancel: true)
        XCTAssertTrue(agent.ended); XCTAssertEqual(agent.cancels, 2)
        sessions.turnStarted(agent)
        sessions.turnEnded(agent, cancel: false)
        XCTAssertTrue(agent.ended); XCTAssertEqual(agent.cancels, 2)
        sessions.turnStarted(agent)
        sessions.stop([agent.key])
        XCTAssertFalse(agent.ended); XCTAssertTrue(sessions.isStopped(agent))
        sessions.turnEnded(agent, cancel: true)
        XCTAssertTrue(agent.ended); XCTAssertEqual(agent.cancels, 4)
        sessions.turnStarted(agent)
        XCTAssertFalse(agent.ended); XCTAssertFalse(sessions.isStopped(agent))
        XCTAssertEqual(agent.cancels, 4, "New turns must not reset cancellation generations")
    }

    func testParallelOrdinaryLookupsAndStopDoNotWaitForBlockedProvider() {
        for operation in ["agent", "hostGone", "reap"] {
            let table = Self.processes(), sessions = Sessions(process: table.lookup)
            let agent = sessions.agent(peerPID: 9, env: [:])
            let gate = SessionLookupGate(), finished = DispatchSemaphore(value: 0)
            table.hook = { _, record in
                if gate.claim() { gate.block() }
                return record
            }
            DispatchQueue.global().async {
                switch operation {
                case "agent": XCTAssertTrue(sessions.agent(peerPID: 9, env: ["sample": "old"]) === agent)
                case "hostGone": XCTAssertFalse(sessions.hostGone(agent))
                default: XCTAssertTrue(sessions.reap().isEmpty)
                }
                finished.signal()
            }
            wait(gate.entered)
            defer { gate.resume.signal() }
            let ordinary = DispatchSemaphore(value: 0), stopped = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                XCTAssertTrue(sessions.agent(peerPID: 9, env: ["sample": "new"]) === agent)
                XCTAssertFalse(sessions.hostGone(agent))
                XCTAssertTrue(sessions.reap().isEmpty)
                ordinary.signal()
            }
            DispatchQueue.global().async {
                sessions.stop([agent.key])
                XCTAssertTrue(sessions.isStopped(agent))
                XCTAssertEqual(sessions.cancellationGeneration(agent), 1)
                XCTAssertFalse(sessions.hasEnded(agent))
                stopped.signal()
            }
            wait(ordinary); wait(stopped)
            gate.resume.signal(); wait(finished)
            XCTAssertEqual(agent.env, ["sample": "new"])
            XCTAssertTrue(sessions.isStopped(agent))
        }
    }

    func testIndependentRegistrationsCanCommitWhileAnotherProviderIsBlocked() {
        let gate = SessionLookupGate()
        let sessions = Sessions(process: { pid in
            if pid == 1, gate.claim() { gate.block() }
            return nil
        })
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let agent = sessions.agent(peerPID: 1, env: ["TERM_LLM_SESSION_ID": "slow"])
            XCTAssertFalse(agent.exited)
            finished.signal()
        }
        wait(gate.entered)
        defer { gate.resume.signal() }
        let other = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            XCTAssertFalse(sessions.agent(peerPID: 2, env: ["TERM_LLM_SESSION_ID": "fast"]).exited)
            other.signal()
        }
        wait(other)
        gate.resume.signal(); wait(finished)
    }

    func testReentrantProviderCanRefreshSameExplicitIDWithoutRetryOrOldEnvironmentWrite() {
        let table = Self.processes(), reference = SessionReference(), gate = SessionLookupGate()
        let sessions = Sessions(process: table.lookup)
        reference.value = sessions
        let env = ["TERM_LLM_SESSION_ID": "same", "sample": "new"]
        table.hook = { pid, record in
            if pid == 9, gate.claim(), let sessions = reference.value {
                let nested = sessions.agent(peerPID: 9, env: env)
                sessions.stop([nested.key])
                XCTAssertTrue(sessions.isStopped(nested))
                XCTAssertTrue(sessions.reap().isEmpty)
            }
            return record
        }
        let agent = sessions.agent(peerPID: 9, env: ["TERM_LLM_SESSION_ID": "same", "sample": "old"])
        XCTAssertFalse(agent.exited)
        XCTAssertEqual(agent.env, env)
        XCTAssertTrue(sessions.isStopped(agent))
        XCTAssertEqual(agent.cancels, 1)
    }

    func testProviderRefreshingOnEverySampleDoesNotRetryOrSpin() {
        let table = Self.processes(), reference = SessionReference()
        let sessions = Sessions(process: table.lookup), calls = OSAllocatedUnfairLock(initialState: 0)
        reference.value = sessions
        table.hook = { pid, record in
            if pid == 9, let sessions = reference.value {
                let count = calls.withLock { $0 += 1; return $0 }
                // Bound the negative case too: a retry implementation must fail
                // this test rather than strand a worker in an infinite loop.
                if count <= 4 {
                    _ = sessions.agent(peerPID: 123, env: ["TERM_LLM_SESSION_ID": "same", "sample": "nested"])
                } else {
                    XCTFail("Provider was retried after every reentrant registry update")
                }
            }
            return record
        }
        let agent = sessions.agent(peerPID: 9, env: ["TERM_LLM_SESSION_ID": "same", "sample": "outer"])
        XCTAssertEqual(calls.withLock { $0 }, 1)
        XCTAssertEqual(agent.env["sample"], "nested")
        XCTAssertFalse(agent.exited)
    }

    func testProviderCallbacksInAgentHostGoneAndReapCanReenterFromAnotherWorker() {
        for operation in ["agent", "hostGone", "reap"] {
            let table = Self.processes(), sessions = Sessions(process: table.lookup)
            let agent = sessions.agent(peerPID: 9, env: [:]), gate = SessionLookupGate()
            table.hook = { _, record in
                if gate.claim() {
                    let done = DispatchSemaphore(value: 0)
                    DispatchQueue.global().async {
                        sessions.stop([agent.key])
                        XCTAssertTrue(sessions.isStopped(agent))
                        XCTAssertEqual(sessions.cancellationGeneration(agent), 1)
                        done.signal()
                    }
                    XCTAssertEqual(done.wait(timeout: .now() + 2), .success, "\(operation) held registry lock during provider call")
                }
                return record
            }
            if operation == "agent" { XCTAssertTrue(sessions.agent(peerPID: 9, env: [:]) === agent) }
            if operation == "hostGone" { XCTAssertFalse(sessions.hostGone(agent)) }
            if operation == "reap" { XCTAssertTrue(sessions.reap().isEmpty) }
            table.hook = nil // Break the fixture-only callback capture of sessions.
        }
    }

    func testStaleExplicitSampleCannotOverwriteNewerEnvironmentOrHostBundles() {
        let table = Self.processes(), sessions = Sessions(process: table.lookup)
        let gate = SessionLookupGate(), done = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock<AgentSession?>(initialState: nil)
        table.hook = { pid, record in
            if pid == 6, gate.claim() { gate.block() }
            return record
        }
        DispatchQueue.global().async {
            let agent = sessions.agent(peerPID: 9, env: ["TERM_LLM_SESSION_ID": "same", "sample": "old"])
            result.withLock { $0 = agent }; done.signal()
        }
        wait(gate.entered)
        defer { gate.resume.signal() }
        table.set(Self.record(7, 6, "/New.app/Contents/MacOS/term-llm", 3))
        let fresh = sessions.agent(peerPID: 9, env: ["TERM_LLM_SESSION_ID": "same", "sample": "new"])
        gate.resume.signal(); wait(done)
        XCTAssertTrue(result.withLock { $0 } === fresh)
        XCTAssertEqual(fresh.env["sample"], "new")
        XCTAssertEqual(fresh.hosts, ["/New.app", "/Host.app"])
    }

    func testStaleHostGoneSampleCannotDeclareRefreshedSameBirthDead() {
        let table = Self.processes(), sessions = Sessions(process: table.lookup)
        let agent = sessions.agent(peerPID: 9, env: [:]), gate = SessionLookupGate(), done = DispatchSemaphore(value: 0)
        table.hook = { pid, record in
            if pid == 7, gate.claim() { gate.block(); return nil }
            return record
        }
        DispatchQueue.global().async {
            XCTAssertFalse(sessions.hostGone(agent), "A refreshed registration supersedes the old dead sample")
            done.signal()
        }
        wait(gate.entered)
        defer { gate.resume.signal() }
        XCTAssertTrue(sessions.agent(peerPID: 9, env: ["refresh": "same-birth"]) === agent)
        gate.resume.signal(); wait(done)
        XCTAssertFalse(agent.exited)
    }

    func testStaleReapCannotRemoveRefreshedSameBirthOrStopMark() {
        let table = Self.processes(), sessions = Sessions(process: table.lookup)
        let agent = sessions.agent(peerPID: 9, env: [:]), gate = SessionLookupGate(), done = DispatchSemaphore(value: 0)
        table.hook = { pid, record in
            if pid == 7, gate.claim() { gate.block(); return nil }
            return record
        }
        DispatchQueue.global().async {
            XCTAssertTrue(sessions.reap().isEmpty)
            done.signal()
        }
        wait(gate.entered)
        defer { gate.resume.signal() }
        XCTAssertTrue(sessions.agent(peerPID: 9, env: [:]) === agent)
        sessions.stop([agent.key])
        gate.resume.signal(); wait(done)
        XCTAssertFalse(agent.exited)
        XCTAssertTrue(sessions.isStopped(agent))
        XCTAssertEqual(agent.cancels, 1)
    }

    func testStaleReapCannotRemoveReplacementWithSameExplicitIdentity() {
        let table = Self.processes(), sessions = Sessions(process: table.lookup)
        let old = sessions.agent(peerPID: 9, env: [:]), gate = SessionLookupGate(), done = DispatchSemaphore(value: 0)
        table.remove(7)
        table.hook = { pid, record in
            if pid == 7, gate.claim() { gate.block() }
            return record
        }
        DispatchQueue.global().async {
            XCTAssertTrue(sessions.reap().isEmpty)
            done.signal()
        }
        wait(gate.entered)
        defer { gate.resume.signal() }
        XCTAssertEqual(sessions.reap().map(\.key), [old.key])
        let replacement = sessions.agent(peerPID: 123, env: ["TERM_LLM_SESSION_ID": old.key])
        sessions.stop([replacement.key])
        gate.resume.signal(); wait(done)
        XCTAssertTrue(old.exited)
        XCTAssertFalse(replacement === old)
        XCTAssertFalse(replacement.exited)
        XCTAssertTrue(sessions.isStopped(replacement))
        XCTAssertTrue(sessions.agent(peerPID: 123, env: ["TERM_LLM_SESSION_ID": old.key]) === replacement)
    }

    func testStaleShellReapCannotForgetRefreshedOrphanAssociation() {
        let table = Self.processes(), sessions = Sessions(process: table.lookup)
        let agent = sessions.agent(peerPID: 9, env: [:]), gate = SessionLookupGate(), done = DispatchSemaphore(value: 0)
        table.hook = { pid, record in
            if pid == 8, gate.claim() { gate.block(); return nil }
            return record
        }
        DispatchQueue.global().async {
            XCTAssertTrue(sessions.reap().isEmpty)
            done.signal()
        }
        wait(gate.entered)
        defer { gate.resume.signal() }
        XCTAssertTrue(sessions.agent(peerPID: 9, env: [:]) === agent)
        gate.resume.signal(); wait(done)
        table.remove(7)
        table.set(Self.record(8, 6, "/bin/-zsh", 2))
        let orphan = sessions.agent(peerPID: 9, env: [:])
        XCTAssertTrue(orphan.exited)
        XCTAssertEqual(orphan.key, agent.key)
    }

    func testOldAncestryCannotResurrectRegistrationCreatedAndReapedDuringSample() {
        let table = SessionProcesses([Self.record(9, 7, "/client", 1), Self.record(7, 0, "/agent", 3)])
        let sessions = Sessions(process: table.lookup), gate = SessionLookupGate(), done = DispatchSemaphore(value: 0)
        table.hook = { pid, record in
            if pid == 7, gate.claim() { gate.block() }
            return record
        }
        DispatchQueue.global().async {
            XCTAssertTrue(sessions.agent(peerPID: 9, env: [:]).exited, "Do not resurrect an absent -> present -> reaped registration")
            done.signal()
        }
        wait(gate.entered)
        defer { gate.resume.signal() }
        let registered = sessions.agent(peerPID: 9, env: [:])
        table.remove(7)
        XCTAssertEqual(sessions.reap().map(\.key), [registered.key])
        assertLookupOwnership(sessions, active: 1, agents: 1, shells: 0)
        gate.resume.signal(); wait(done)
        assertLookupOwnership(sessions, active: 0, agents: 0, shells: 0)
        XCTAssertTrue(registered.exited)
        XCTAssertTrue(sessions.reap().isEmpty)
    }

    func testStaleAncestryCannotOverwriteNewerWrapperHostAssociation() {
        let table = Self.processes(), sessions = Sessions(process: table.lookup)
        let old = sessions.agent(peerPID: 9, env: [:]), gate = SessionLookupGate(), done = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock<AgentSession?>(initialState: nil)
        // Sample the old host, then allow another lookup to associate the same
        // wrapper birth with a different (also live) host before commit.
        table.hook = { pid, record in
            if pid == 7, gate.claim() { gate.block() }
            return record
        }
        DispatchQueue.global().async {
            let agent = sessions.agent(peerPID: 9, env: [:])
            result.withLock { $0 = agent }
            done.signal()
        }
        wait(gate.entered)
        defer { gate.resume.signal() }
        table.set(Self.record(8, 6, "/bin/-zsh", 2))
        let fresh = sessions.agent(peerPID: 9, env: [:])
        XCTAssertEqual(fresh.key, "6:4.0")
        XCTAssertFalse(fresh.exited)
        gate.resume.signal(); wait(done)
        XCTAssertTrue(result.withLock { $0 } === fresh)
        XCTAssertFalse(result.withLock { $0?.exited } ?? true)
        assertLookupOwnership(sessions, active: 0, agents: 0, shells: 0)
        // If the old sample rewrote shells, this would silently adopt old again.
        table.remove(6)
        table.set(Self.record(8, 7, "/bin/-zsh", 2))
        let orphan = sessions.agent(peerPID: 9, env: [:])
        XCTAssertTrue(orphan.exited)
        XCTAssertEqual(orphan.key, fresh.key)
        XCTAssertFalse(old.exited)
    }

    func testTurnSignalsAndStopRemainResponsiveDuringBlockedLivenessSample() {
        let table = Self.processes(), sessions = Sessions(process: table.lookup)
        let agent = sessions.agent(peerPID: 9, env: [:]), gate = SessionLookupGate(), done = DispatchSemaphore(value: 0)
        table.hook = { _, record in
            if gate.claim() { gate.block() }
            return record
        }
        DispatchQueue.global().async {
            XCTAssertFalse(sessions.hostGone(agent))
            done.signal()
        }
        wait(gate.entered)
        defer { gate.resume.signal() }
        let changed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            sessions.turnStarted(agent)
            sessions.stop([agent.key])
            sessions.letGo(agent, cancel: true)
            XCTAssertTrue(sessions.hasEnded(agent))
            XCTAssertTrue(sessions.isStopped(agent))
            sessions.turnStarted(agent)
            XCTAssertFalse(sessions.hasEnded(agent))
            XCTAssertFalse(sessions.isStopped(agent))
            sessions.turnEnded(agent, cancel: true)
            XCTAssertEqual(sessions.cancellationGeneration(agent), 3)
            changed.signal()
        }
        wait(changed)
        gate.resume.signal(); wait(done)
        XCTAssertTrue(agent.ended)
        XCTAssertEqual(agent.cancels, 3)
    }

    func testNewLiveAgentSurvivesUnrelatedHostRetirement() throws {
        let table = Self.processes(), sessions = Sessions(process: table.lookup)
        Self.addTree(table, host: 17)
        let other = sessions.agent(peerPID: 19, env: [:])
        let agent = try parkedLookup(sessions, table: table) {
            table.remove(17)
            XCTAssertEqual(sessions.reap().map(\.key), [other.key])
            assertLookupOwnership(sessions, active: 1, agents: 1, shells: 0)
        }
        XCTAssertEqual(agent.key, "7:3.0")
        XCTAssertFalse(agent.exited)
        XCTAssertFalse(sessions.hostGone(agent))
        XCTAssertTrue(sessions.agent(peerPID: 9, env: [:]) === agent)
        assertLookupOwnership(sessions, active: 0, agents: 0, shells: 0)
    }

    func testNewLiveAgentSurvivesUnrelatedShellOnlyRetirement() throws {
        let table = Self.processes(), sessions = Sessions(process: table.lookup)
        Self.addTree(table, host: 17)
        let other = sessions.agent(peerPID: 19, env: [:])
        let agent = try parkedLookup(sessions, table: table) {
            table.remove(18)
            XCTAssertTrue(sessions.reap().isEmpty)
            assertLookupOwnership(sessions, active: 1, agents: 0, shells: 1)
        }
        XCTAssertFalse(agent.exited)
        XCTAssertFalse(sessions.hostGone(other))
        XCTAssertTrue(sessions.agent(peerPID: 9, env: [:]) === agent)
        assertLookupOwnership(sessions, active: 0, agents: 0, shells: 0)
    }

    func testExistingLiveAgentRecordsFreshWrapperDespitePriorWrapperRetirement() throws {
        let table = Self.processes(), sessions = Sessions(process: table.lookup)
        let live = sessions.agent(peerPID: 9, env: [:])
        table.remove(8)
        table.set(Self.record(10, 7, "/bin/zsh", 5))
        table.set(Self.record(11, 10, "/fake/client", 6))
        let agent = try parkedLookup(sessions, table: table, peerPID: 11) {
            XCTAssertTrue(sessions.reap().isEmpty)
            assertLookupOwnership(sessions, active: 1, agents: 0, shells: 1)
        }
        XCTAssertTrue(agent === live)
        XCTAssertFalse(agent.exited)
        // The fresh wrapper must have been recorded, not merely returned with
        // a compatible live agent: it must remember that host after orphaning.
        table.remove(7)
        table.set(Self.record(10, 6, "/bin/zsh", 5))
        let orphan = sessions.agent(peerPID: 11, env: [:])
        XCTAssertTrue(orphan.exited)
        XCTAssertEqual(orphan.key, live.key)
        assertLookupOwnership(sessions, active: 0, agents: 0, shells: 0)
    }

    func testFirstExplicitIDRegistrationSurvivesUnrelatedRetirement() throws {
        let table = Self.processes(), sessions = Sessions(process: table.lookup)
        Self.addTree(table, host: 17)
        let other = sessions.agent(peerPID: 19, env: [:])
        let env = ["TERM_LLM_SESSION_ID": "chat-42"]
        let agent = try parkedLookup(sessions, table: table, env: env) {
            table.remove(17)
            XCTAssertEqual(sessions.reap().map(\.key), [other.key])
        }
        XCTAssertEqual(agent.key, "chat-42")
        XCTAssertFalse(agent.exited)
        XCTAssertFalse(sessions.hostGone(agent))
        XCTAssertEqual(agent.env, env)
        XCTAssertTrue(sessions.agent(peerPID: 9, env: env) === agent)
        assertLookupOwnership(sessions, active: 0, agents: 0, shells: 0)
    }

    func testNextTurnUsesLiveAgentWhilePriorWrapperIsReaped() throws {
        let table = Self.processes(), sessions = Sessions(process: table.lookup)
        let live = sessions.agent(peerPID: 9, env: [:])
        sessions.turnStarted(live)
        live.denied.insert("refused"); live.instructed.insert("instructions")
        sessions.stop([live.key])
        sessions.letGo(live, cancel: true)
        XCTAssertTrue(sessions.hasEnded(live))
        table.remove(8)
        table.set(Self.record(10, 7, "/bin/zsh", 5))
        table.set(Self.record(11, 10, "/fake/client", 6))
        let hookAgent = try parkedLookup(sessions, table: table, peerPID: 11) {
            XCTAssertTrue(sessions.reap().isEmpty)
        }
        XCTAssertTrue(hookAgent === live)
        sessions.turnStarted(hookAgent)
        let toolAgent = sessions.agent(peerPID: 11, env: [:])
        XCTAssertTrue(toolAgent === live)
        XCTAssertFalse(live.exited)
        XCTAssertFalse(sessions.hasEnded(live))
        XCTAssertFalse(sessions.isStopped(live))
        XCTAssertTrue(live.denied.isEmpty); XCTAssertTrue(live.instructed.isEmpty)
        XCTAssertEqual(live.cancels, 2)
        table.remove(7)
        table.set(Self.record(10, 6, "/bin/zsh", 5))
        XCTAssertEqual(sessions.agent(peerPID: 11, env: [:]).key, live.key)
        assertLookupOwnership(sessions, active: 0, agents: 0, shells: 0)
    }

    func testSupersededOrphanSampleUsesReentrantRemappedRegistration() {
        let table = Self.processes(), sessions = Sessions(process: table.lookup), reference = SessionReference()
        reference.value = sessions
        let old = sessions.agent(peerPID: 9, env: [:]), once = SessionLookupGate()
        table.set(Self.record(8, 6, "/bin/-zsh", 2))
        let nested = OSAllocatedUnfairLock<AgentSession?>(initialState: nil)
        table.hook = { pid, record in
            if pid == 7, once.claim(), let sessions = reference.value {
                let agent = sessions.agent(peerPID: 9, env: ["sample": "nested"])
                nested.withLock { $0 = agent }
                table.remove(7)
                return nil
            }
            return record
        }
        let outer = sessions.agent(peerPID: 9, env: ["sample": "outer"])
        table.hook = nil // Release the fixture callback's table capture.
        XCTAssertTrue(outer === nested.withLock { $0 })
        XCTAssertEqual(outer.key, "6:4.0")
        XCTAssertFalse(outer.exited)
        XCTAssertEqual(outer.env, ["sample": "nested"])
        XCTAssertTrue(sessions.agent(peerPID: 9, env: [:]) === outer)
        XCTAssertFalse(old.exited)
        assertLookupOwnership(sessions, active: 0, agents: 0, shells: 0)
    }

    func testSupersededOrphanSampleUsesConcurrentlyRemappedRegistration() throws {
        let table = Self.processes(), sessions = Sessions(process: table.lookup)
        let old = sessions.agent(peerPID: 9, env: [:])
        table.set(Self.record(8, 6, "/bin/-zsh", 2))
        let current = OSAllocatedUnfairLock<AgentSession?>(initialState: nil)
        let outer = try parkedLookup(sessions, table: table, at: 7, missingSample: true) {
            let agent = sessions.agent(peerPID: 9, env: ["sample": "new"])
            current.withLock { $0 = agent }
            table.remove(7)
        }
        XCTAssertTrue(outer === current.withLock { $0 })
        XCTAssertEqual(outer.key, "6:4.0")
        XCTAssertFalse(outer.exited)
        XCTAssertEqual(outer.env, ["sample": "new"])
        XCTAssertTrue(sessions.agent(peerPID: 9, env: [:]) === outer)
        XCTAssertFalse(old.exited)
        assertLookupOwnership(sessions, active: 0, agents: 0, shells: 0)
    }

    func testRefreshedSampledHostWinsOverUnchangedOldWrapperAssociation() throws {
        let table = Self.processes(), sessions = Sessions(process: table.lookup)
        let old = sessions.agent(peerPID: 9, env: ["sample": "old-host"])
        // A separate peer reaches H directly, without a wrapper or explicit ID.
        table.set(Self.record(10, 6, "/fake/other-client", 10))
        let current = sessions.agent(peerPID: 10, env: ["sample": "before"])
        table.set(Self.record(8, 6, "/bin/-zsh", 2))
        let sampled = try parkedLookup(sessions, table: table, env: ["sample": "outer"], at: 6) {
            // Refresh only H's entry; the wrapper still records its old host.
            XCTAssertTrue(sessions.agent(peerPID: 10, env: ["sample": "refreshed"]) === current)
        }
        XCTAssertTrue(sampled === current)
        XCTAssertFalse(sampled === old)
        XCTAssertEqual(sampled.key, "6:4.0")
        XCTAssertFalse(sampled.exited)
        XCTAssertFalse(old.exited)
        XCTAssertEqual(current.env, ["sample": "refreshed"])
        XCTAssertEqual(old.env, ["sample": "old-host"])
        // A discarded sample must not rewrite even the unchanged old mapping.
        table.remove(7)
        let orphan = sessions.agent(peerPID: 9, env: [:])
        XCTAssertTrue(orphan.exited)
        XCTAssertEqual(orphan.key, old.key)
        XCTAssertFalse(sessions.hostGone(current))
        assertLookupOwnership(sessions, active: 0, agents: 0, shells: 0)
    }

    func testStaleSampleReportsRetiredCurrentHostNotUnregisteredLiveSampledHost() throws {
        let table = Self.processes(), sessions = Sessions(process: table.lookup)
        let old = sessions.agent(peerPID: 9, env: [:])
        table.set(Self.record(8, 6, "/bin/-zsh", 2))
        let retiredKey = OSAllocatedUnfairLock(initialState: "")
        let result = try parkedLookup(sessions, table: table, at: 6) {
            table.set(Self.record(17, 0, "/fake/new-agent", 17))
            table.set(Self.record(8, 17, "/bin/-zsh", 2))
            let current = sessions.agent(peerPID: 9, env: [:])
            retiredKey.withLock { $0 = current.key }
            table.remove(17)
            XCTAssertEqual(sessions.reap().map(\.key), [current.key])
        }
        XCTAssertTrue(result.exited)
        XCTAssertEqual(result.key, retiredKey.withLock { $0 })
        XCTAssertNotEqual(result.key, "6:4.0", "The sampled live host was never retired")
        XCTAssertFalse(old.exited)
        assertLookupOwnership(sessions, active: 0, agents: 0, shells: 0)
    }

    func testOrphanReturnPrunesRetirementsAndReleasesItsLookupEpoch() throws {
        let table = Self.processes(), sessions = Sessions(process: table.lookup)
        let old = sessions.agent(peerPID: 9, env: [:])
        Self.addTree(table, host: 17)
        let other = sessions.agent(peerPID: 19, env: [:])
        table.remove(7)
        table.set(Self.record(8, 6, "/bin/-zsh", 2))
        let orphan = try parkedLookup(sessions, table: table, at: 7) {
            table.remove(17); table.remove(18)
            XCTAssertEqual(Set(sessions.reap().map(\.key)), [old.key, other.key])
            assertLookupOwnership(sessions, active: 1, agents: 2, shells: 1)
        }
        XCTAssertEqual(orphan.key, old.key)
        XCTAssertTrue(orphan.exited)
        assertLookupOwnership(sessions, active: 0, agents: 0, shells: 0)
        // Reaping with no active lookup must not retain tombstones either.
        table.remove(8)
        XCTAssertTrue(sessions.reap().isEmpty)
        assertLookupOwnership(sessions, active: 0, agents: 0, shells: 0)
    }

    func testSharedLookupRevisionKeepsRetirementsUntilLastReaderReturns() {
        let table = Self.processes(), sessions = Sessions(process: table.lookup)
        let old = sessions.agent(peerPID: 9, env: [:])
        let first = SessionLookupGate(), second = SessionLookupGate()
        let firstDone = DispatchSemaphore(value: 0), secondDone = DispatchSemaphore(value: 0)
        table.hook = { pid, record in
            if pid == 101, first.claim() { first.block() }
            if pid == 102, second.claim() { second.block() }
            return record
        }
        DispatchQueue.global().async {
            XCTAssertFalse(sessions.agent(peerPID: 101, env: ["TERM_LLM_SESSION_ID": "first"]).exited)
            firstDone.signal()
        }
        DispatchQueue.global().async {
            XCTAssertFalse(sessions.agent(peerPID: 102, env: ["TERM_LLM_SESSION_ID": "second"]).exited)
            secondDone.signal()
        }
        wait(first.entered); wait(second.entered)
        defer { first.resume.signal(); second.resume.signal() }
        assertLookupOwnership(sessions, active: 2, agents: 0, shells: 0)
        table.remove(7); table.remove(8)
        XCTAssertEqual(sessions.reap().map(\.key), [old.key])
        assertLookupOwnership(sessions, active: 2, agents: 1, shells: 1)
        first.resume.signal(); wait(firstDone)
        assertLookupOwnership(sessions, active: 1, agents: 1, shells: 1)
        second.resume.signal(); wait(secondDone)
        assertLookupOwnership(sessions, active: 0, agents: 0, shells: 0)
    }

    func testTombstonesPruneWhenOldestActiveEpochAdvances() {
        let table = Self.processes(), sessions = Sessions(process: table.lookup)
        let oldAgent = sessions.agent(peerPID: 9, env: [:])
        Self.addTree(table, host: 17); Self.addTree(table, host: 27)
        let firstDead = sessions.agent(peerPID: 19, env: [:])
        let youngAgent = sessions.agent(peerPID: 29, env: [:])
        let old = SessionLookupGate(), young = SessionLookupGate()
        let oldDone = DispatchSemaphore(value: 0), youngDone = DispatchSemaphore(value: 0)
        table.hook = { pid, record in
            if pid == 7, old.claim() { old.block() }
            return record
        }
        DispatchQueue.global().async {
            XCTAssertTrue(sessions.agent(peerPID: 9, env: [:]) === oldAgent)
            oldDone.signal()
        }
        wait(old.entered)
        defer { old.resume.signal(); young.resume.signal() }
        table.remove(17); table.remove(18)
        XCTAssertEqual(sessions.reap().map(\.key), [firstDead.key])
        assertLookupOwnership(sessions, active: 1, agents: 1, shells: 1)
        table.hook = { pid, record in
            if pid == 7, old.claim() { old.block() }
            if pid == 27, young.claim() { young.block() }
            return record
        }
        DispatchQueue.global().async {
            XCTAssertTrue(sessions.agent(peerPID: 29, env: [:]) === youngAgent)
            youngDone.signal()
        }
        wait(young.entered)
        Self.addTree(table, host: 37)
        let secondDead = sessions.agent(peerPID: 39, env: [:])
        table.remove(37); table.remove(38)
        XCTAssertEqual(sessions.reap().map(\.key), [secondDead.key])
        assertLookupOwnership(sessions, active: 2, agents: 2, shells: 2)
        old.resume.signal(); wait(oldDone)
        // Only the later retirement is relevant to the remaining younger lookup.
        assertLookupOwnership(sessions, active: 1, agents: 1, shells: 1)
        young.resume.signal(); wait(youngDone)
        assertLookupOwnership(sessions, active: 0, agents: 0, shells: 0)
    }

    func testMissingShellTombstonePreventsStaleAssociationResurrection() throws {
        let table = Self.processes(), sessions = Sessions(process: table.lookup)
        let old = sessions.agent(peerPID: 123, env: ["TERM_LLM_SESSION_ID": "7:3.0"])
        let current = OSAllocatedUnfairLock<AgentSession?>(initialState: nil)
        let sampled = try parkedLookup(sessions, table: table) {
            table.set(Self.record(8, 6, "/bin/-zsh", 2))
            let agent = sessions.agent(peerPID: 9, env: [:])
            current.withLock { $0 = agent }
            table.remove(8)
            XCTAssertTrue(sessions.reap().isEmpty)
            assertLookupOwnership(sessions, active: 1, agents: 0, shells: 1)
        }
        XCTAssertTrue(sampled === old)
        XCTAssertFalse(sampled.exited)
        // A stale commit would restore 8 -> 7, then incorrectly reject 8 -> 6
        // as an orphan after 7 disappears. The shell tombstone prevents that.
        table.remove(7)
        table.set(Self.record(8, 6, "/bin/-zsh", 2))
        let fresh = sessions.agent(peerPID: 9, env: [:])
        XCTAssertTrue(fresh === current.withLock { $0 })
        XCTAssertEqual(fresh.key, "6:4.0")
        XCTAssertFalse(fresh.exited)
        assertLookupOwnership(sessions, active: 0, agents: 0, shells: 0)
    }

    func testConcurrentCancellationIncrementsStayAtomicWithExternalAgentStateUsers() {
        let sessions = Sessions(process: { _ in nil })
        let agent = sessions.agent(peerPID: 1, env: ["TERM_LLM_SESSION_ID": "counter"])
        sessions.turnStarted(agent)
        DispatchQueue.concurrentPerform(iterations: 600) { index in
            switch index % 4 {
            case 0: sessions.stop([agent.key])
            case 1: sessions.letGo(agent, cancel: true)
            case 2: sessions.turnEnded(agent, cancel: true)
            default: agent.withState { agent.cancels += 1 }
            }
        }
        XCTAssertEqual(sessions.cancellationGeneration(agent), 600)
        XCTAssertTrue(agent.ended)
        XCTAssertTrue(sessions.isStopped(agent))
        sessions.turnStarted(agent)
        XCTAssertEqual(agent.cancels, 600)
        XCTAssertFalse(sessions.hasEnded(agent))
        XCTAssertFalse(sessions.isStopped(agent))
    }
}
