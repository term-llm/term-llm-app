import ComputerUseCore
import XCTest

@testable import ComputerUseSystem

final class ApprovalsTests: XCTestCase {
    var folder: URL!, store: ApprovalStore!, agent: AgentSession!, questions: [Ask]!,
        withdrawn: [String]!, time = 0.0
    let target = AppTarget(
        path: "/Applications/TextEdit.app", bundleID: "com.apple.TextEdit", name: "TextEdit")
    var policy = PolicyDecision(decision: .allowed, risk: .low, allowPersistent: true, warning: nil)
    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = ApprovalStore(directory: folder)
        agent = AgentSession(key: "named-session")
        questions = []
        withdrawn = []
        time = 0
    }
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }
    func make(answer: String? = nil, available: Bool = true, sleep: ((Double) -> Void)? = nil)
        -> Approvals
    {
        Approvals(
            store: store,
            ask: { q in
                self.questions.append(q)
                if let answer { q.onAnswer(answer) }
                return available
            }, withdraw: { self.withdrawn.append($0) }, now: { self.time },
            sleep: sleep ?? { self.time += $0 })
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
        let a = make(sleep: { dt in
            self.time += dt
            self.questions[0].onAnswer(Approvals.session)
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
            }, alive: { $0 == "42:1234" })
        XCTAssertTrue(a.approved(agent: processAgent, bundleID: target.bundleID, policy: policy))
    }
}
