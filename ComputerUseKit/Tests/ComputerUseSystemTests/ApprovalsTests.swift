import ComputerUseCore
import XCTest
import os

@testable import ComputerUseSystem

// All tests use a private store and explicit fake UI/clock/process hooks.
// Callbacks capture this synchronized recorder, never the XCTest owner.
private final class ApprovalFixture: Sendable {
    struct State: Sendable {
        var questions: [Ask] = []
        var withdrawn: [String] = []
        var time = 0.0
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    var questions: [Ask] { state.withLock { $0.questions } }
    var withdrawn: [String] { state.withLock { $0.withdrawn } }
    var time: Double { state.withLock { $0.time } }
}

final class ApprovalsTests: XCTestCase {
    var folder: URL!, store: ApprovalStore!, agent: AgentSession!
    private var fixture: ApprovalFixture!
    var questions: [Ask] { fixture.questions }
    var withdrawn: [String] { fixture.withdrawn }
    var time: Double { fixture.time }
    let target = AppTarget(
        path: "/Applications/TextEdit.app", bundleID: "com.apple.TextEdit", name: "TextEdit")
    var policy = PolicyDecision(decision: .allowed, risk: .low, allowPersistent: true, warning: nil)
    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = ApprovalStore(directory: folder)
        agent = AgentSession(key: "named-session")
        fixture = ApprovalFixture()
    }
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }
    func make(
        answer: String? = nil, available: Bool = true,
        ask: (@Sendable (Ask) -> Bool)? = nil,
        withdraw: (@Sendable (String) -> Void)? = nil,
        sleep: (@Sendable (Double) -> Void)? = nil,
        alive: @escaping @Sendable (String) -> Bool = { Approvals.namedSessionAlive($0) }
    ) -> Approvals
    {
        let fixture = fixture!
        return Approvals(
            store: store,
            ask: { q in
                fixture.state.withLock { $0.questions.append(q) }
                if let answer { q.onAnswer(answer) }
                return ask?(q) ?? available
            }, withdraw: { title in
                fixture.state.withLock { $0.withdrawn.append(title) }
                withdraw?(title)
            },
            now: { fixture.time },
            sleep: sleep ?? { dt in fixture.state.withLock { $0.time += dt } },
            alive: alive)
    }
    func expect(_ key: String, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body()) {
            XCTAssertEqual(($0 as? HarnessError)?.name, Errors.make(key).name)
        }
    }
    func testQuestionNamesPersonAndAppAndChoices() {
        let a = make()
        expect("approval_pending") {
            try a.ensure(agent: agent, target: target, policy: policy, deadline: 10)
        }
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions[0].title, "May \(product) control \"TextEdit\"?")
        XCTAssertNil(questions[0].subtitle)
        XCTAssertEqual(questions[0].choices, [Approvals.deny, Approvals.session, Approvals.always])
    }
    func testSessionYesOnlyHoldsForThisAgentAndSurvivesRestart() throws {
        let a = make(answer: Approvals.session)
        try a.ensure(agent: agent, target: target, policy: policy, deadline: 100)
        XCTAssertTrue(a.approved(agent: agent, bundleID: target.bundleID, policy: policy))
        XCTAssertFalse(
            a.approved(agent: AgentSession(key: "other"), bundleID: target.bundleID, policy: policy)
        )
        XCTAssertTrue(make().approved(agent: agent, bundleID: target.bundleID, policy: policy))
        XCTAssertTrue(store.always().isEmpty)
        try a.ensure(agent: agent, target: target, policy: policy, deadline: 100)
        XCTAssertEqual(questions.count, 1)
    }
    func testAlwaysApprovalAndPolicyPersistentSwitch() throws {
        let a = make(answer: Approvals.always)
        try a.ensure(agent: agent, target: target, policy: policy, deadline: 100)
        let other = AgentSession(key: "other")
        XCTAssertTrue(make().approved(agent: other, bundleID: target.bundleID, policy: policy))
        XCTAssertNotNil(store.always()[target.bundleID])
        var p = policy
        p.allowPersistent = false
        XCTAssertFalse(make().approved(agent: other, bundleID: target.bundleID, policy: p))
    }
    func testDenyRememberedForSignalledTurn() {
        agent.signalsTurns = true
        let a = make(answer: Approvals.deny)
        for _ in 0..<2 {
            expect("not_approved") {
                try a.ensure(agent: agent, target: target, policy: policy, deadline: 100)
            }
        }
        XCTAssertEqual(questions.count, 1)
        a.clearDenials(agent: agent)
        expect("not_approved") {
            try a.ensure(agent: agent, target: target, policy: policy, deadline: 100)
        }
        XCTAssertEqual(questions.count, 2)
    }
    func testNoTurnSignalsDenyRefusesOnlyOneCall() {
        let a = make(answer: Approvals.deny)
        for _ in 0..<2 {
            expect("not_approved") {
                try a.ensure(agent: agent, target: target, policy: policy, deadline: 100)
            }
        }
        XCTAssertEqual(questions.count, 2)
        XCTAssertTrue(agent.denied.isEmpty)
    }
    func testAnythingButYesDenies() {
        let a = make(answer: "unexpected")
        expect("not_approved") {
            try a.ensure(agent: agent, target: target, policy: policy, deadline: 100)
        }
    }
    func testPendingPromptStaysAndAnswerAppliesToNextCall() throws {
        let a = make()
        expect("approval_pending") {
            try a.ensure(agent: agent, target: target, policy: policy, deadline: 11)
        }
        XCTAssertEqual(time, 1)
        expect("approval_pending") {
            try a.ensure(agent: agent, target: target, policy: policy, deadline: 11)
        }
        XCTAssertEqual(questions.count, 1)
        questions[0].onAnswer(Approvals.session)
        try a.ensure(agent: agent, target: target, policy: policy, deadline: 11)
    }
    func testAbandonedCallStopsWaitingWithoutWithdrawing() {
        let a = make()
        expect("request_timed_out") {
            try a.ensure(
                agent: agent, target: target, policy: policy, deadline: 100, abandoned: { true })
        }
        XCTAssertEqual(questions.count, 1)
        XCTAssertTrue(withdrawn.isEmpty)
    }
    func testAnswerAtNextPollEndsWait() throws {
        let fixture = fixture!
        let a = make(sleep: { dt in
            fixture.state.withLock { $0.time += dt }
            fixture.questions[0].onAnswer(Approvals.session)
        })
        try a.ensure(agent: agent, target: target, policy: policy, deadline: 100)
        XCTAssertEqual(time, 0.25)
    }
    func testUnavailablePanelRefusesAndRetriesNextTime() {
        let a = make(available: false)
        for _ in 0..<2 {
            expect("approval_unavailable") {
                try a.ensure(agent: agent, target: target, policy: policy, deadline: 100)
            }
        }
        XCTAssertEqual(questions.count, 2)
    }
    func testControlSocketGrantWithdrawsQuestionAndLiftsDeny() throws {
        let a = make()
        expect("approval_pending") {
            try a.ensure(agent: agent, target: target, policy: policy, deadline: 10)
        }
        agent.denied.insert(target.path)
        try a.approve(bundleID: target.bundleID, always: false)
        XCTAssertEqual(withdrawn, [questions[0].title])
        try a.ensure(agent: agent, target: target, policy: policy, deadline: 100)
        XCTAssertTrue(
            a.approved(agent: AgentSession(key: "other"), bundleID: target.bundleID, policy: policy)
        )
    }
    func testRefusedPolicyCannotBeBypassedWithNoAsk() {
        for decision in [PolicyDecision.Decision.denied, .forbidden] {
            var p = policy
            p.ask = false
            p.decision = decision
            expect(decision == .denied ? "denied_by_policy" : "forbidden") {
                try make().ensure(agent: agent, target: target, policy: p, deadline: 0)
            }
        }
        XCTAssertTrue(questions.isEmpty)
    }
    func testNoAskSkipsPrompt() throws {
        var p = policy
        p.ask = false
        try make().ensure(agent: agent, target: target, policy: p, deadline: 0)
        XCTAssertTrue(questions.isEmpty)
    }
    func testPolicyWarningAndNoPersistentChoice() {
        var p = policy
        p.allowPersistent = false
        p.warning = "warning"
        let a = make()
        expect("approval_pending") {
            try a.ensure(agent: agent, target: target, policy: p, deadline: 0)
        }
        XCTAssertEqual(questions[0].choices, [Approvals.deny, Approvals.session])
        XCTAssertEqual(questions[0].subtitle, "warning")
    }
    func testPIDTargetsHaveNoAlwaysChoiceAndCannotPersist() throws {
        let t = AppTarget(path: "#pid:42", bundleID: "#pid:42", name: "process")
        let a = make()
        expect("approval_pending") {
            try a.ensure(agent: agent, target: t, policy: policy, deadline: 0)
        }
        XCTAssertEqual(questions[0].choices, [Approvals.deny, Approvals.session])
        try a.approve(bundleID: t.bundleID, always: true)
        XCTAssertTrue(store.always().isEmpty)
    }
    func testDiskFailureStillAllowsSession() throws {
        try Data().write(to: folder)  // state directory is a regular file
        let a = make(answer: Approvals.always)
        try a.ensure(agent: agent, target: target, policy: policy, deadline: 100)
        XCTAssertTrue(a.approved(agent: agent, bundleID: target.bundleID, policy: policy))
        XCTAssertTrue(store.always().isEmpty)
        expect("approval_not_saved") { try a.approve(bundleID: "other", always: true) }
        XCTAssertTrue(a.approved(agent: agent, bundleID: "other", policy: policy))
    }
    func testProcessSessionKeysFailClosedWithoutProcessLookup() throws {
        XCTAssertFalse(Approvals.namedSessionAlive("42:1234"))
        XCTAssertTrue(Approvals.namedSessionAlive("term-session"))
        try store.saveSession(agent: "42:1234", bundleID: target.bundleID, alive: { _ in true })
        let processAgent = AgentSession(key: "42:1234")
        XCTAssertFalse(
            make().approved(agent: processAgent, bundleID: target.bundleID, policy: policy))
        let a = Approvals(
            store: store,
            ask: { _ in
                XCTFail()
                return false
            }, withdraw: { _ in XCTFail("Unexpected withdrawal") }, now: { 0 },
            sleep: { _ in XCTFail("Unexpected sleep") }, alive: { $0 == "42:1234" })
        XCTAssertTrue(a.approved(agent: processAgent, bundleID: target.bundleID, policy: policy))
    }
    func testSynchronousAnswerWinsEvenAtPendingDeadline() throws {
        let a = make(answer: Approvals.session)
        try a.ensure(agent: agent, target: target, policy: policy, deadline: 0)
        XCTAssertEqual(time, 0)
        XCTAssertEqual(questions.count, 1)
    }
    func testDuplicateAndWithdrawnAnswersCannotOverrideDirectGrant() throws {
        let a = make()
        expect("approval_pending") {
            try a.ensure(agent: agent, target: target, policy: policy, deadline: 0)
        }
        let stale = questions[0]
        try a.approve(bundleID: target.bundleID, always: false)
        stale.onAnswer(Approvals.deny)
        stale.onAnswer(Approvals.always)
        XCTAssertTrue(agent.denied.isEmpty)
        XCTAssertTrue(store.always().isEmpty)
        XCTAssertEqual(withdrawn, [stale.title])
        try a.ensure(agent: agent, target: target, policy: policy, deadline: 0)
    }
    func testOldUnavailableAnswerCannotSettleReplacement() throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let a = make(ask: { _ in calls.withLock { $0 += 1; return $0 > 1 } })
        expect("approval_unavailable") {
            try a.ensure(agent: agent, target: target, policy: policy, deadline: 0)
        }
        expect("approval_pending") {
            try a.ensure(agent: agent, target: target, policy: policy, deadline: 0)
        }
        questions[0].onAnswer(Approvals.always)
        questions[0].onAnswer(Approvals.deny)
        XCTAssertFalse(a.approved(agent: agent, bundleID: target.bundleID, policy: policy))
        XCTAssertTrue(store.always().isEmpty)
        XCTAssertTrue(agent.denied.isEmpty)
        expect("approval_pending") {
            try a.ensure(agent: agent, target: target, policy: policy, deadline: 0)
        }
        XCTAssertEqual(questions.count, 2)
        questions[1].onAnswer(Approvals.session)
        try a.ensure(agent: agent, target: target, policy: policy, deadline: 0)
    }
    func testNewTurnWithdrawsAndRejectsOldYesAndNo() throws {
        let a = make()
        expect("approval_pending") {
            try a.ensure(agent: agent, target: target, policy: policy, deadline: 0)
        }
        let old = questions[0]
        a.beginTurn(agent: agent)
        expect("approval_pending") {
            try a.ensure(agent: agent, target: target, policy: policy, deadline: 0)
        }
        XCTAssertEqual(questions.count, 2)
        old.onAnswer(Approvals.always)
        old.onAnswer(Approvals.deny)
        XCTAssertTrue(agent.denied.isEmpty)
        XCTAssertFalse(a.approved(agent: agent, bundleID: target.bundleID, policy: policy))
        XCTAssertTrue(store.always().isEmpty)
        XCTAssertEqual(withdrawn, [old.title])
        questions[1].onAnswer(Approvals.session)
        a.beginTurn(agent: agent)
        try a.ensure(agent: agent, target: target, policy: policy, deadline: 0)
    }
    func testCancellationCounterInvalidatesQuestionBeforeTurnCleanup() throws {
        let a = make()
        expect("approval_pending") {
            try a.ensure(agent: agent, target: target, policy: policy, deadline: 0)
        }
        let old = questions[0]
        agent.cancels += 1
        old.onAnswer(Approvals.always)
        XCTAssertFalse(a.approved(agent: agent, bundleID: target.bundleID, policy: policy))
        expect("approval_pending") {
            try a.ensure(agent: agent, target: target, policy: policy, deadline: 0)
        }
        old.onAnswer(Approvals.deny)
        XCTAssertEqual(questions.count, 2)
        XCTAssertEqual(withdrawn, [])
        XCTAssertTrue(agent.denied.isEmpty)
        questions[1].onAnswer(Approvals.session)
        try a.ensure(agent: agent, target: target, policy: policy, deadline: 0)
    }
    func testEndedAndExitedAgentsCannotAcceptPendingAnswers() {
        for exited in [false, true] {
            let a = make()
            expect("approval_pending") {
                try a.ensure(agent: agent, target: target, policy: policy, deadline: 0)
            }
            let q = questions.last!
            if exited { agent.exited = true } else { agent.ended = true }
            q.onAnswer(Approvals.always)
            XCTAssertFalse(a.approved(agent: agent, bundleID: target.bundleID, policy: policy))
            expect("request_timed_out") {
                try a.ensure(agent: agent, target: target, policy: policy, deadline: 100)
            }
            agent.ended = false
            agent.exited = false
        }
    }
    func testUnadvertisedAlwaysChoiceDoesNotCreateGrant() {
        var p = policy
        p.allowPersistent = false
        let a = make()
        expect("approval_pending") {
            try a.ensure(agent: agent, target: target, policy: p, deadline: 0)
        }
        questions[0].onAnswer(Approvals.always)
        XCTAssertFalse(a.approved(agent: agent, bundleID: target.bundleID, policy: p))
        XCTAssertTrue(store.always().isEmpty)
    }
    func testTitleWithdrawalRestoresOtherAgentQuestionWithoutGrantingIt() throws {
        let panel = AskQueue()
        let first = agent!
        let second = AgentSession(key: "second")
        let a = make(ask: { panel.append($0); return true }, withdraw: { panel.withdraw(title: $0) })
        for owner in [first, second] {
            expect("approval_pending") {
                try a.ensure(agent: owner, target: target, policy: policy, deadline: 0)
            }
        }
        let old = panel.asks[0]
        a.cancel(keys: [first.key])
        XCTAssertEqual(panel.asks.count, 1)
        XCTAssertTrue(panel.asks[0] === questions[1])
        old.onAnswer(Approvals.session)
        XCTAssertFalse(a.approved(agent: first, bundleID: target.bundleID, policy: policy))
        XCTAssertFalse(a.approved(agent: second, bundleID: target.bundleID, policy: policy))
        panel.answer(panel.asks[0], choice: Approvals.session)
        XCTAssertTrue(a.approved(agent: second, bundleID: target.bundleID, policy: policy))
        XCTAssertFalse(a.approved(agent: first, bundleID: target.bundleID, policy: policy))
    }
    func testAskWithdrawAndProcessLookupDoNotHoldStateLock() throws {
        let holder = OSAllocatedUnfairLock<Approvals?>(initialState: nil)
        let probe: @Sendable () -> Void = {
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                let a = holder.withLock { $0! }
                _ = a.stored()
                done.signal()
            }
            XCTAssertEqual(done.wait(timeout: .now() + 2), .success, "State access blocked by callback")
        }
        try store.saveSession(agent: "other", bundleID: "other", alive: { _ in true })
        let a = make(ask: { _ in probe(); return true }, withdraw: { _ in probe() },
                     alive: { _ in probe(); return true })
        holder.withLock { $0 = a }
        expect("approval_pending") {
            try a.ensure(agent: agent, target: target, policy: policy, deadline: 0)
        }
        try a.approve(bundleID: target.bundleID, always: false)
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(withdrawn.count, 1)
        holder.withLock { $0 = nil }
    }
    func testSynchronousAnswerPersistenceDoesNotHoldStateLock() throws {
        let holder = OSAllocatedUnfairLock<Approvals?>(initialState: nil)
        let checks = OSAllocatedUnfairLock(initialState: 0)
        try store.saveSession(agent: "other", bundleID: "other", alive: { _ in true })
        let a = make(answer: Approvals.session, alive: { _ in
            checks.withLock { $0 += 1 }
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                _ = holder.withLock { $0! }.stored()
                done.signal()
            }
            XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
            return true
        })
        holder.withLock { $0 = a }
        try a.ensure(agent: agent, target: target, policy: policy, deadline: 0)
        XCTAssertGreaterThanOrEqual(checks.withLock { $0 }, 2, "Probe both lookup and answer persistence")
        XCTAssertTrue(store.sessions(alive: { _ in true }).contains(
            .init(agent: agent.key, bundleID: target.bundleID)))
        holder.withLock { $0 = nil }
    }
    func testReentrantDirectGrantIsWithdrawnAfterAskReturns() throws {
        let holder = OSAllocatedUnfairLock<Approvals?>(initialState: nil)
        let order = OSAllocatedUnfairLock<[String]>(initialState: [])
        let bundle = target.bundleID
        let a = make(ask: { _ in
            order.withLock { $0.append("show") }
            try? holder.withLock { $0! }.approve(bundleID: bundle, always: false)
            order.withLock { $0.append("shown") }
            return true
        }, withdraw: { _ in order.withLock { $0.append("withdraw") } })
        holder.withLock { $0 = a }
        try a.ensure(agent: agent, target: target, policy: policy, deadline: 0)
        XCTAssertEqual(order.withLock { $0 }, ["show", "shown", "withdraw"])
        questions[0].onAnswer(Approvals.deny)
        XCTAssertTrue(agent.denied.isEmpty)
        holder.withLock { $0 = nil }
    }
    func testConcurrentWaitersReserveOneQuestionAndGrantCanProgressDuringShow() throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let a = make(ask: { _ in
            entered.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return true
        })
        let owner = agent!, target = target, policy = policy
        DispatchQueue.global().async {
            defer { finished.signal() }
            do { try a.ensure(agent: owner, target: target, policy: policy, deadline: 0) }
            catch { XCTFail("Grant should settle showing request: \(error)") }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        let waiters = DispatchGroup()
        for _ in 0..<8 {
            waiters.enter()
            DispatchQueue.global().async {
                defer { waiters.leave() }
                do {
                    try a.ensure(agent: owner, target: target, policy: policy, deadline: 0)
                    XCTFail("Expected pending question")
                } catch { XCTAssertEqual((error as? HarnessError)?.name, Errors.make("approval_pending").name) }
            }
        }
        XCTAssertEqual(waiters.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(questions.count, 1)
        try a.approve(bundleID: target.bundleID, always: false)
        XCTAssertTrue(a.approved(agent: owner, bundleID: target.bundleID, policy: policy))
        XCTAssertTrue(withdrawn.isEmpty, "Do not withdraw before the in-flight show returns")
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(withdrawn, [questions[0].title])
        questions[0].onAnswer(Approvals.deny)
        XCTAssertTrue(owner.denied.isEmpty)
    }
    func testTurnChangeDuringShowCancelsOldWaiterAndQueuesFreshQuestion() throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let a = make(ask: { _ in
            entered.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return true
        })
        let owner = agent!, target = target, policy = policy
        DispatchQueue.global().async {
            defer { finished.signal() }
            do {
                try a.ensure(agent: owner, target: target, policy: policy, deadline: 0)
                XCTFail("Old request survived turn boundary")
            } catch { XCTAssertEqual((error as? HarnessError)?.name, Errors.make("request_timed_out").name) }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        a.beginTurn(agent: owner)
        questions[0].onAnswer(Approvals.always)
        XCTAssertFalse(a.approved(agent: owner, bundleID: target.bundleID, policy: policy))
        // The drainer is busy, but reserving a new-generation question must not wait.
        expect("approval_pending") {
            try a.ensure(agent: owner, target: target, policy: policy, deadline: 0)
        }
        release.signal()
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(questions.count, 2)
        XCTAssertEqual(withdrawn, [questions[0].title])
        questions[0].onAnswer(Approvals.deny)
        XCTAssertTrue(owner.denied.isEmpty)
        questions[1].onAnswer(Approvals.session)
        try a.ensure(agent: owner, target: target, policy: policy, deadline: 0)
    }
    func testReentrantWithdrawalCanAskWithoutSelfWaiting() {
        let holder = OSAllocatedUnfairLock<Approvals?>(initialState: nil)
        let owner = agent!, target = target, policy = policy
        let a = make(withdraw: { _ in
            do {
                try holder.withLock { $0! }.ensure(
                    agent: owner, target: target, policy: policy, deadline: 0)
                XCTFail("New question should be pending")
            } catch { XCTAssertEqual((error as? HarnessError)?.name, Errors.make("approval_pending").name) }
        })
        holder.withLock { $0 = a }
        expect("approval_pending") {
            try a.ensure(agent: owner, target: target, policy: policy, deadline: 0)
        }
        a.beginTurn(agent: owner)
        XCTAssertEqual(questions.count, 2)
        XCTAssertEqual(withdrawn.count, 1)
        holder.withLock { $0 = nil }
    }
    private func whilePersistenceBlocked(_ a: Approvals, _ body: () throws -> Void) rethrows {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            a.persistence.withLock { _ in
                entered.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            }
            finished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        defer {
            release.signal()
            XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        }
        try body()
    }
    private func waitForSessionGrants(_ a: Approvals, _ bundles: Set<String>) {
        let deadline = Date().addingTimeInterval(2)
        while !Set(a.stored().session).isSuperset(of: bundles) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertTrue(Set(a.stored().session).isSuperset(of: bundles))
    }
    func testConcurrentDirectGrantsSerializePersistentCommitsOutsideStateLock() {
        let a = make()
        let bundles: Set<String> = ["first", "second"]
        let finished = DispatchGroup(), returned = DispatchSemaphore(value: 0)
        whilePersistenceBlocked(a) {
            for bundle in bundles {
                finished.enter()
                DispatchQueue.global().async {
                    defer { returned.signal(); finished.leave() }
                    do { try a.approve(bundleID: bundle, always: true) }
                    catch { XCTFail("Private approval write failed: \(error)") }
                }
            }
            // Both state transitions proceed while filesystem commits are paused.
            waitForSessionGrants(a, bundles)
            XCTAssertEqual(returned.wait(timeout: .now() + 0.05), .timedOut)
            XCTAssertTrue(store.always().isEmpty)
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(Set(store.always().keys), bundles)
    }
    func testDirectPersistentFailureIsReportedSynchronouslyAfterCommitGate() throws {
        try Data().write(to: folder)
        let a = make()
        let finished = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock<String?>(initialState: nil)
        whilePersistenceBlocked(a) {
            DispatchQueue.global().async {
                defer { finished.signal() }
                do {
                    try a.approve(bundleID: "app", always: true)
                    XCTFail("Expected approval_not_saved")
                } catch { result.withLock { $0 = (error as? HarnessError)?.name } }
            }
            waitForSessionGrants(a, ["app"])
            XCTAssertEqual(finished.wait(timeout: .now() + 0.05), .timedOut)
            XCTAssertNil(result.withLock { $0 })
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(result.withLock { $0 }, Errors.make("approval_not_saved").name)
        XCTAssertTrue(a.approved(agent: agent, bundleID: "app", policy: policy))
    }
    func testConcurrentSessionAnswersRetryStaleLivenessSampleAndKeepBothBundles() throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let firstFinished = DispatchSemaphore(value: 0), secondFinished = DispatchSemaphore(value: 0)
        let paused = OSAllocatedUnfairLock(initialState: false)
        let a = make(alive: { _ in
            let first = paused.withLock { paused in
                if paused { return false }
                paused = true
                return true
            }
            if first {
                entered.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            }
            return true
        })
        let second = AppTarget(path: "/fake/second.app", bundleID: "second", name: "Second")
        for target in [target, second] {
            expect("approval_pending") {
                try a.ensure(agent: agent, target: target, policy: policy, deadline: 0)
            }
        }
        // A row forces liveness evaluation after the first save's disk snapshot.
        try store.saveSession(agent: "seed", bundleID: "seed", alive: { _ in true })
        let firstQuestion = questions[0], secondQuestion = questions[1]
        DispatchQueue.global().async {
            firstQuestion.onAnswer(Approvals.session)
            firstFinished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        defer { release.signal() }
        DispatchQueue.global().async {
            secondQuestion.onAnswer(Approvals.session)
            secondFinished.signal()
        }
        // Liveness is outside the commit gate: the second answer must finish
        // before releasing the first sample, then the first must retry its read.
        XCTAssertEqual(secondFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(firstFinished.wait(timeout: .now() + 0.05), .timedOut)
        XCTAssertTrue(store.sessions(alive: { _ in true }).contains(
            .init(agent: agent.key, bundleID: second.bundleID)))
        release.signal()
        XCTAssertEqual(firstFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(store.sessions(alive: { _ in true }), [
            .init(agent: "seed", bundleID: "seed"),
            .init(agent: agent.key, bundleID: target.bundleID),
            .init(agent: agent.key, bundleID: second.bundleID),
        ])
    }
    func testReentrantSessionAnswerDuringLivenessKeepsBothBundles() throws {
        let nextAnswer = OSAllocatedUnfairLock<Ask?>(initialState: nil)
        let a = make(alive: { _ in
            let next = nextAnswer.withLock { question in
                let next = question
                question = nil
                return next
            }
            next?.onAnswer(Approvals.session)
            return true
        })
        let second = AppTarget(path: "/fake/second.app", bundleID: "second", name: "Second")
        for target in [target, second] {
            expect("approval_pending") {
                try a.ensure(agent: agent, target: target, policy: policy, deadline: 0)
            }
        }
        try store.saveSession(agent: "seed", bundleID: "seed", alive: { _ in true })
        let secondQuestion = questions[1]
        nextAnswer.withLock { $0 = secondQuestion }
        let first = questions[0], finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            first.onAnswer(Approvals.session)
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success, "Reentrant answer self-waited")
        XCTAssertEqual(store.sessions(alive: { _ in true }), [
            .init(agent: "seed", bundleID: "seed"),
            .init(agent: agent.key, bundleID: target.bundleID),
            .init(agent: agent.key, bundleID: second.bundleID),
        ])
    }

    func testActiveWaitStopWithdrawsAndOtherTitleCleanupCannotResurrectIt() {
        let panel = AskQueue()
        let owner = agent!, other = AgentSession(key: "other")
        let holder = OSAllocatedUnfairLock<Approvals?>(initialState: nil)
        let target = target, policy = policy
        let a = make(ask: { panel.append($0); return true }, withdraw: { panel.withdraw(title: $0) },
                     sleep: { _ in
            let a = holder.withLock { $0! }
            do { try a.ensure(agent: other, target: target, policy: policy, deadline: 0) }
            catch { XCTAssertEqual((error as? HarnessError)?.name, Errors.make("approval_pending").name) }
            owner.cancels += 1  // Sessions.stop changes this without a turn boundary.
        })
        holder.withLock { $0 = a }
        expect("request_timed_out") {
            try a.ensure(agent: owner, target: target, policy: policy, deadline: 100)
        }
        XCTAssertEqual(panel.asks.count, 1)
        XCTAssertTrue(panel.asks[0] === questions[1])
        XCTAssertEqual(withdrawn, [questions[0].title])
        a.cancel(keys: [other.key])
        XCTAssertTrue(panel.asks.isEmpty)
        XCTAssertEqual(a.generationCount, 0)
        questions[0].onAnswer(Approvals.always)
        XCTAssertFalse(a.approved(agent: owner, bundleID: target.bundleID, policy: policy))
        holder.withLock { $0 = nil }
    }
    func testConsumedStaleAnswerCannotBeRestoredByAnotherAgentsWithdrawal() {
        let panel = AskQueue()
        let owner = agent!, other = AgentSession(key: "other")
        let a = make(ask: { panel.append($0); return true }, withdraw: { panel.withdraw(title: $0) })
        for agent in [owner, other] {
            expect("approval_pending") {
                try a.ensure(agent: agent, target: target, policy: policy, deadline: 0)
            }
        }
        let dead = panel.asks[0]
        owner.cancels += 1
        panel.answer(dead, choice: Approvals.session)
        XCTAssertEqual(panel.asks.count, 1)
        XCTAssertTrue(withdrawn.isEmpty, "The panel already consumed the matching stale question")
        a.cancel(keys: [other.key])
        XCTAssertTrue(panel.asks.isEmpty)
        XCTAssertEqual(a.generationCount, 0)
        XCTAssertFalse(a.approved(agent: owner, bundleID: target.bundleID, policy: policy))
    }
    func testCancellationAfterShowDrainsMatchingWithdrawalBeforeThrowing() {
        let panel = AskQueue(), owner = agent!
        let a = make(ask: { q in
            panel.append(q)
            owner.cancels += 1
            return true
        }, withdraw: { panel.withdraw(title: $0) })
        expect("request_timed_out") {
            try a.ensure(agent: owner, target: target, policy: policy, deadline: 100)
        }
        XCTAssertTrue(panel.asks.isEmpty)
        XCTAssertEqual(withdrawn, [questions[0].title])
        XCTAssertEqual(a.generationCount, 0)
    }
    func testOldCancelledWaiterCannotWithdrawNewCancelSnapshotQuestion() throws {
        let panel = AskQueue(), owner = agent!
        let holder = OSAllocatedUnfairLock<Approvals?>(initialState: nil)
        let target = target, policy = policy
        let a = make(ask: { panel.append($0); return true }, withdraw: { panel.withdraw(title: $0) },
                     sleep: { _ in
            owner.cancels += 1
            do {
                try holder.withLock { $0! }.ensure(
                    agent: owner, target: target, policy: policy, deadline: 0)
                XCTFail("Replacement question should remain pending")
            } catch { XCTAssertEqual((error as? HarnessError)?.name, Errors.make("approval_pending").name) }
        })
        holder.withLock { $0 = a }
        expect("request_timed_out") {
            try a.ensure(agent: owner, target: target, policy: policy, deadline: 100)
        }
        XCTAssertEqual(questions.count, 2)
        XCTAssertEqual(withdrawn, [questions[0].title])
        XCTAssertEqual(panel.asks.count, 1)
        XCTAssertTrue(panel.asks[0] === questions[1])
        questions[0].onAnswer(Approvals.deny)
        panel.answer(questions[1], choice: Approvals.session)
        try a.ensure(agent: owner, target: target, policy: policy, deadline: 0)
        XCTAssertEqual(a.generationCount, 0)
        holder.withLock { $0 = nil }
    }
    func testNormalDenialCleanupKeepsPendingQuestionAnswerable() throws {
        let a = make()
        expect("approval_pending") {
            try a.ensure(agent: agent, target: target, policy: policy, deadline: 0)
        }
        let old = questions[0]
        a.clearDenials(agent: agent)
        XCTAssertTrue(withdrawn.isEmpty)
        old.onAnswer(Approvals.session)
        try a.ensure(agent: agent, target: target, policy: policy, deadline: 0)
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(a.generationCount, 0)
    }
    func testGenerationTrackingDoesNotRetainNeverAskedOrExitedAgents() {
        let a = make()
        for index in 0..<40 {
            let neverAsked = AgentSession(key: "unused-\(index)")
            a.clearDenials(agent: neverAsked)
            a.beginTurn(agent: neverAsked)
            a.cancel(keys: [neverAsked.key])
            XCTAssertEqual(a.generationCount, 0)
            let asked = AgentSession(key: "exited-\(index)")
            expect("approval_pending") {
                try a.ensure(agent: asked, target: target, policy: policy, deadline: 0)
            }
            XCTAssertEqual(a.generationCount, 1)
            asked.exited = true
            a.cancel(keys: [asked.key])
            XCTAssertEqual(a.generationCount, 0)
        }
        XCTAssertTrue(store.always().isEmpty)
    }

}
