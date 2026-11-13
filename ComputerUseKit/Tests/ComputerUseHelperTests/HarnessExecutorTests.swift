import ComputerUseCore
import ComputerUseSystem
import CoreGraphics
import Foundation
import os
import XCTest

@testable import ComputerUseHelper

private final class ExecutorElement: NSObject, Sendable {
    // Mutable fixture state is owned by this lock. Snapshots contain value data,
    // immutable test values, synchronized nodes, or @Sendable callbacks. Hooks run
    // outside locks; heterogeneous values never escape to asynchronous work.
    // uncheckedState/withLockUnchecked admit operation-local Any; attrs must
    // contain immutable fixture values or separately synchronized handles.
    private struct State {
        var attrs: [String: Any] = [:]
        var pid: pid_t = 77
        var id: UInt32 = 7
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    var attrs: [String: Any] {
        get { state.withLockUnchecked { $0.attrs } }
        set { state.withLockUnchecked { $0.attrs = newValue } }
    }
    var pid: pid_t {
        get { state.withLockUnchecked { $0.pid } }
        set { state.withLockUnchecked { $0.pid = newValue } }
    }
    var id: UInt32 {
        get { state.withLockUnchecked { $0.id } }
        set { state.withLockUnchecked { $0.id = newValue } }
    }

    func set(_ name: String, _ value: Any) { state.withLockUnchecked { $0.attrs[name] = value } }
    var ref: UIElementRef { UIElementRef(self) }
}
private final class ExecutorObservation: AXObservation {
    private let closed = OSAllocatedUnfairLock(initialState: false)
    var stopped: Bool { closed.withLock { $0 } }
    func stop() { closed.withLock { $0 = true } }
}
private final class ExecutorAX: AXBackend {
    // Mutable fixture state is owned by this lock. Snapshots contain value data,
    // immutable test values, synchronized nodes, or @Sendable callbacks. Hooks run
    // outside locks; heterogeneous values never escape to asynchronous work.
    private struct State: Sendable {
        var error: Error? = nil
        var observations: [ExecutorObservation] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var error: Error? {
        get { state.withLock { $0.error } }
        set { state.withLock { $0.error = newValue } }
    }
    var observations: [ExecutorObservation] {
        get { state.withLock { $0.observations } }
        set { state.withLock { $0.observations = newValue } }
    }

    let root = ExecutorElement(), window = ExecutorElement(), field = ExecutorElement()
    init() {
        root.attrs = ["AXWindows": [window.ref], "AXFocusedWindow": window.ref]
        window.attrs = ["AXRole": "AXWindow", "AXTitle": "Demo", "AXMain": true]
        field.id = 0
        field.attrs = ["AXRole": "AXButton", "AXParent": window.ref, "AXWindow": window.ref]
    }
    func app(pid: pid_t) -> UIElementRef { root.ref }
    func get(_ e: UIElementRef, _ n: String) throws -> Any? {
        if let error { throw error }
        return (e.object as! ExecutorElement).attrs[n]
    }
    func names(_ e: UIElementRef) -> [String] { [] }
    func getMany(_ e: UIElementRef, _ n: [String]) throws -> [Any?] { try n.map { try get(e, $0) } }
    func set(_ e: UIElementRef, _ n: String, _ v: Any) throws {
        (e.object as! ExecutorElement).set(n, v)
    }
    func settable(_ e: UIElementRef, _ n: String) -> Bool { true }
    func actionNames(_ e: UIElementRef) -> [String] { [] }
    func actionDescription(_ e: UIElementRef, _ a: String) -> String { "" }
    func perform(_ e: UIElementRef, _ a: String) throws {
        XCTFail("Executor tests must not perform AX actions")
    }
    func param(_ e: UIElementRef, _ n: String, _ a: Any) -> Any? { nil }
    func pid(_ e: UIElementRef) throws -> pid_t { (e.object as! ExecutorElement).pid }
    func windowID(_ e: UIElementRef) -> UInt32 { (e.object as! ExecutorElement).id }
    func frame(_ e: UIElementRef) -> CGRect? { CGRect(x: 100, y: 50, width: 400, height: 300) }
    func at(_ a: UIElementRef?, x: Double, y: Double) -> UIElementRef? { nil }
    func alive(_ e: UIElementRef) -> Bool { true }
    func observe(
        pid: pid_t, element: UIElementRef, names: [String],
        callback: @escaping @Sendable (String, UIElementRef) -> Void
    ) throws -> AXObservation {
        let o = ExecutorObservation()
        state.withLock { $0.observations.append(o) }
        return o
    }
}

/// All mutable callback-visible fixture state is typed and checked Sendable.
/// Dependencies retain callbacks that retain this world; tearDown explicitly
/// retires executor/dependencies before releasing the world.
private final class ExecutorWorld: Sendable {
    private let axState = HelperFixtureBox<ExecutorAX?>(nil)
    var ax: ExecutorAX! {
        get { axState.value }
        set { axState.value = newValue }
    }
    private let oldAXState = HelperFixtureBox<AXBackend?>(nil)
    var oldAX: AXBackend! {
        get { oldAXState.value }
        set { oldAXState.value = newValue }
    }
    private let homeState = HelperFixtureBox<URL?>(nil)
    var home: URL! {
        get { homeState.value }
        set { homeState.value = newValue }
    }
    private let dependenciesState = HelperFixtureBox<HarnessExecutor.Dependencies?>(nil)
    var dependencies: HarnessExecutor.Dependencies! {
        get { dependenciesState.value }
        set { dependenciesState.value = newValue }
    }
    private let executorState = HelperFixtureBox<HarnessExecutor?>(nil)
    var executor: HarnessExecutor! {
        get { executorState.value }
        set { executorState.value = newValue }
    }
    private let sessionsState = HelperFixtureBox<Sessions?>(nil)
    var sessions: Sessions! {
        get { sessionsState.value }
        set { sessionsState.value = newValue }
    }
    private let agentState = HelperFixtureBox<AgentSession?>(nil)
    var agent: AgentSession! {
        get { agentState.value }
        set { agentState.value = newValue }
    }
    private let logState = HelperFixtureBox<[String]>([])
    var log: [String] {
        get { logState.value }
        set { logState.value = newValue }
    }
    private let targetsState = HelperFixtureBox<[Actions.Target]>([])
    var targets: [Actions.Target] {
        get { targetsState.value }
        set { targetsState.value = newValue }
    }
    private let abandonedState = HelperFixtureBox<Bool>(false)
    var abandoned: Bool {
        get { abandonedState.value }
        set { abandonedState.value = newValue }
    }
    private let nowState = HelperFixtureBox<Double>(1000)
    var now: Double {
        get { nowState.value }
        set { nowState.value = newValue }
    }
    private let captureState = HelperFixtureBox<Capture?>(nil)
    var capture: Capture! {
        get { captureState.value }
        set { captureState.value = newValue }
    }
    private let screenshotErrorState = HelperFixtureBox<HarnessError?>(nil)
    var screenshotError: HarnessError? {
        get { screenshotErrorState.value }
        set { screenshotErrorState.value = newValue }
    }
    private let readErrorState = HelperFixtureBox<Error?>(nil)
    var readError: Error? {
        get { readErrorState.value }
        set { readErrorState.value = newValue }
    }
    private let sendErrorState = HelperFixtureBox<Error?>(nil)
    var sendError: Error? {
        get { sendErrorState.value }
        set { sendErrorState.value = newValue }
    }
    private let runningState = HelperFixtureBox<Bool>(true)
    var running: Bool {
        get { runningState.value }
        set { runningState.value = newValue }
    }
    private let switchedOnState = HelperFixtureBox<Bool>(false)
    var switchedOn: Bool {
        get { switchedOnState.value }
        set { switchedOnState.value = newValue }
    }
    private let settledState = HelperFixtureBox<Capture?>(nil)
    var settled: Capture? {
        get { settledState.value }
        set { settledState.value = newValue }
    }
    private let queuePathState = HelperFixtureBox<String>("")
    var queuePath: String {
        get { queuePathState.value }
        set { queuePathState.value = newValue }
    }
    private let seenIgnoreState = HelperFixtureBox<[Bool]>([])
    var seenIgnore: [Bool] {
        get { seenIgnoreState.value }
        set { seenIgnoreState.value = newValue }
    }
    let target = AppTarget(
        path: "/Applications/Demo.app", bundleID: "dev.demo", name: "Demo", pid: 77)
    func record(_ entry: String) { logState.update { $0.append(entry) } }
    func recordIgnore(_ value: Bool) { seenIgnoreState.update { $0.append(value) } }
    func advance(_ seconds: Double) { nowState.update { $0 += seconds } }
    func makeCapture(_ value: String = "OK") -> Capture {
        Capture(
            windowTitle: "Demo", appName: "Demo", windowID: 7,
            lines: [Line(depth: 0, text: "button \(value)", element: ax.field.ref,
                         role: "AXButton", name: "OK", value: value)])
    }
}

final class HarnessExecutorTests: XCTestCase {
    override func invokeTest() { AX.withBackend(AX.backend) { super.invokeTest() } }
    private let world = ExecutorWorld()
    private var ax: ExecutorAX! {
        get { world.ax }
        set { world.ax = newValue }
    }
    private var oldAX: AXBackend! {
        get { world.oldAX }
        set { world.oldAX = newValue }
    }
    private var home: URL! {
        get { world.home }
        set { world.home = newValue }
    }
    private var dependencies: HarnessExecutor.Dependencies! {
        get { world.dependencies }
        set { world.dependencies = newValue }
    }
    private var executor: HarnessExecutor! {
        get { world.executor }
        set { world.executor = newValue }
    }
    private var sessions: Sessions! {
        get { world.sessions }
        set { world.sessions = newValue }
    }
    private var agent: AgentSession! {
        get { world.agent }
        set { world.agent = newValue }
    }
    private var log: [String] {
        get { world.log }
        set { world.log = newValue }
    }
    private var targets: [Actions.Target] {
        get { world.targets }
        set { world.targets = newValue }
    }
    private var abandoned: Bool {
        get { world.abandoned }
        set { world.abandoned = newValue }
    }
    private var now: Double {
        get { world.now }
        set { world.now = newValue }
    }
    private var capture: Capture! {
        get { world.capture }
        set { world.capture = newValue }
    }
    private var screenshotError: HarnessError? {
        get { world.screenshotError }
        set { world.screenshotError = newValue }
    }
    private var readError: Error? {
        get { world.readError }
        set { world.readError = newValue }
    }
    private var sendError: Error? {
        get { world.sendError }
        set { world.sendError = newValue }
    }
    private var running: Bool {
        get { world.running }
        set { world.running = newValue }
    }
    private var switchedOn: Bool {
        get { world.switchedOn }
        set { world.switchedOn = newValue }
    }
    private var settled: Capture? {
        get { world.settled }
        set { world.settled = newValue }
    }
    private var queuePath: String {
        get { world.queuePath }
        set { world.queuePath = newValue }
    }
    private var seenIgnore: [Bool] {
        get { world.seenIgnore }
        set { world.seenIgnore = newValue }
    }
    private var target: AppTarget { world.target }
    override func setUpWithError() throws {
        let world = world
        oldAX = AX.backend
        ax = ExecutorAX()
        AX.backend = ax
        home = FileManager.default.temporaryDirectory.appendingPathComponent("executor-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        log = []
        targets = []
        now = 1000
        abandoned = false
        screenshotError = nil
        readError = nil
        sendError = nil
        running = true
        switchedOn = false
        settled = nil
        queuePath = ""
        seenIgnore = []
        sessions = Sessions(process: { _ in nil })
        agent = sessions.agent(peerPID: 1, env: ["TERM_LLM_SESSION_ID": "test"])
        capture = makeCapture()
        var apps = Apps.System()
        apps.executable = { _ in world.running ? world.target.path + "/Contents/MacOS/Demo" : "" }
        apps.running = { [] }
        apps.realPath = { $0 }
        apps.expandUser = { $0 }
        apps.info = { _ in [:] }
        apps.regular = { _ in true }
        apps.processBundleID = { _ in "dev.demo" }
        apps.panelServices = { [:] }
        apps.frontPIDs = { [] }
        apps.used = { [] }
        apps.entries = { _ in [] }
        apps.bundlePaths = { _ in [] }
        apps.named = { _ in nil }
        apps.open = { _ in
            world.record("launch")
            world.running = true
            return 77
        }
        apps.keyWindow = { _ in
            .init(
                element: world.ax.window.ref, windowID: 7, pid: 77, title: "Demo",
                frame: world.ax.frame(world.ax.window.ref)!)
        }
        var windows = Windows.System()
        windows.rows = { _, _ in [] }
        windows.associated = { _ in [] }
        windows.noAttention = { _ in }
        windows.now = { world.now }
        windows.sleep = { world.advance($0) }
        let person = Person.System(
            now: { world.now },
            sleep: { world.advance($0) },
            frontmostPID: { 88 }, bundleOf: { _ in "" }, hidIdle: { _ in .infinity },
            secureInputPID: { nil }, windowPID: { _ in 0 }, canListen: { false })
        var focus = Focus.System()
        focus.frontPID = { 88 }
        focus.noAttention = { _ in }
        focus.personWent = { _, _ in false }
        focus.post = { _, _ in XCTFail("No posted activation") }
        focus.background = { _ in }
        dependencies = HarnessExecutor.Dependencies()
        dependencies.apps = Apps(system: apps)
        dependencies.windows = Windows(system: windows)
        dependencies.person = Person(system: person)
        dependencies.focus = Focus(system: focus)
        dependencies.presence = Presence(
            enabled: { false }, send: { _ in XCTFail("No overlay") },
            ask: { _ in XCTFail("No panel") },
            withdraw: { _ in })
        dependencies.policy = Policy(
            managedFile: home.appendingPathComponent("managed"),
            userFile: home.appendingPathComponent("user"))
        dependencies.approvals = Approvals(
            store: ApprovalStore(directory: home),
            ask: { _ in
                XCTFail("No real approval")
                return false
            }, withdraw: { _ in })
        dependencies.instructions = Instructions(stateDirectory: { [home = home!] in home })
        dependencies.screenshot = Screenshot(
            folder: home.appendingPathComponent("cache"), stateDirectory: { [home = home!] in home })
        var actionsSystem = dependencies.actions.system
        actionsSystem.pasteboard = ComputerUseSystem.Pasteboard(
            board: {
                XCTFail("No real clipboard")
                return .init(snapshot: { [] }, write: { _ in nil }, restore: { _, _ in false })
            }, stateDirectory: { [home = home!] in home })
        dependencies.actions = Actions(system: actionsSystem)
        dependencies.resolve = { _ in
            world.record("resolve")
            return world.target
        }
        dependencies.decide = { _, _ in
            world.record("policy")
            return PolicyDecision(
                decision: .allowed, risk: .low, allowPersistent: false, warning: nil)
        }
        dependencies.ensureApproval = { _, _, _, _, _ in world.record("approval") }
        dependencies.permissionsGate = { _, _ in world.record("permissions") }
        dependencies.lockGate = { _ in world.record("lock") }
        dependencies.personGate = { _, _, _, _ in world.record("person") }
        dependencies.read = { _, _, _, _ in
            world.record("read")
            if let error = world.readError { throw error }
            return world.capture
        }
        dependencies.enable = { _, _ in
            world.record("enable")
            return world.switchedOn
        }
        dependencies.disable = { _ in world.record("disable") }
        dependencies.askOnce = { _ in world.record("askOnce") }
        dependencies.watchRevisions = { revisions, target in
            world.record("watch")
            try revisions.watch(target)
        }
        dependencies.settle = { _, _, _, poll, _ in
            world.record(poll == 0.05 ? "settleFresh" : "settle")
            XCTAssertFalse(world.executor.appSessions(world.agent).first?.needsSettle ?? false)
            return world.settled
        }
        dependencies.picture = { _, _ in
            world.record("picture")
            if let e = world.screenshotError { throw e }
            return Shot(
                path: "/tmp/demo.jpg", scale: 2, origin: CGPoint(x: 100, y: 50), width: 800,
                height: 600)
        }
        dependencies.send = { call, _, targets in
            world.record("send:\(call.name)")
            world.targets = targets
            if let e = world.sendError { throw e }
        }
        dependencies.now = { world.now }
        dependencies.uptime = { world.now }
        executor = HarnessExecutor(dependencies: dependencies)
    }
    override func tearDownWithError() throws {
        defer {
            AX.backend = oldAX
            // Break world -> executor/dependencies -> callback -> world cycles,
            // including callbacks retained by app sessions after a failed cleanup.
            executor = nil
            dependencies = nil
            capture = nil
            settled = nil
            targets = []
            agent = nil
            sessions = nil
            ax = nil
            oldAX = nil
            try? FileManager.default.removeItem(at: home)
        }
        // Only the fake app sessions are cleaned, never the real default primitives.
        if let executor, let agent {
            try executor.letGo(agent, withAppQueue: { _, work in try work() })
        }
    }
    private func makeCapture(_ value: String = "OK") -> Capture {
        world.makeCapture(value)
    }
    private func rebuild() { executor = HarnessExecutor(dependencies: dependencies) }
    private func call(
        _ name: String = "get_app_state", _ args: [String: Any] = [:], deadline: Double = 1120,
        env: [String: String] = [:], other: AgentSession? = nil
    ) -> ToolCallRequest {
        let world = world
        let parsed = try! ToolParser.parse([name])
        var a = parsed.arguments
        a["app"] = "Demo"
        a.merge(args) { _, v in v }
        return ToolCallRequest(
            name: name, arguments: a, stdin: nil, environment: env, agent: other ?? agent,
            sessions: sessions, cwd: "/", deadline: Date(timeIntervalSince1970: deadline),
            abandoned: { world.abandoned },
            withCleanupQueue: { path, work in
                world.record("cleanupQueue")
                return try work()
            },
            withAppQueue: { path, work in
                world.queuePath = path
                world.record("queue")
                return try work()
            })
    }
    @discardableResult private func read() throws -> ToolOutcome { try executor.execute(call()) }
    private func fail(
        _ key: String, _ work: () throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try work(), file: file, line: line) {
            XCTAssertEqual(
                ($0 as? HarnessError)?.message, Errors.make(key).message, file: file, line: line)
        }
    }
    func testReadOrderAndCanonicalQueueAndSecondReadDoesNotSwitchOnAgain() throws {
        let out = try read()
        XCTAssertEqual(
            log,
            [
                "resolve", "policy", "approval", "permissions", "lock", "person", "queue", "person",
                "enable", "watch", "read", "picture",
            ])
        XCTAssertEqual(queuePath, target.path)
        XCTAssertTrue(out.stdout.contains("\n\nScreenshot (800x600 px): /tmp/demo.jpg\n"))
        XCTAssertTrue(executor.appSessions(agent)[0].active)
        log = []
        try read()
        XCTAssertFalse(log.contains("enable") || log.contains("watch"))
        XCTAssertEqual(log.filter { $0 == "person" }.count, 2)
    }
    func testToolChecksPrecedeAppAndEndedPrecedesResolution() throws {
        for (name, args) in [
            ("click", ["element_index": "bad"]), ("scroll", ["pages": "0"]),
            ("press_key", ["key": " "]),
        ] {
            XCTAssertThrowsError(try executor.execute(call(name, args)))
            XCTAssertTrue(log.isEmpty)
        }
        sessions.turnEnded(agent, cancel: true)
        fail("turn_ended") { _ = try self.executor.execute(self.call()) }
        XCTAssertTrue(log.isEmpty)
        XCTAssertThrowsError(try executor.execute(call("get_app_state", ["app": " "]))) {
            XCTAssertTrue(($0 as? HarnessError)?.isUsage == true)
        }
    }
    func testGateFailuresStopAtThatStepAndSecondPersonGateIsNotSkipped() {
        let world = world
        for name in ["policy", "approval", "permissions", "lock", "person"] {
            log = []
            var d = dependencies!
            let error = Errors.make("paused")
            switch name {
            case "policy":
                d.decide = { _, _ in
                    world.record(name)
                    throw error
                }
            case "approval":
                d.ensureApproval = { _, _, _, _, _ in
                    world.record(name)
                    throw error
                }
            case "permissions":
                d.permissionsGate = { _, _ in
                    world.record(name)
                    throw error
                }
            case "lock":
                d.lockGate = { _ in
                    world.record(name)
                    throw error
                }
            default:
                d.personGate = { _, _, _, _ in
                    world.record(name)
                    throw error
                }
            }
            executor = HarnessExecutor(dependencies: d)
            fail("paused") { _ = try self.executor.execute(self.call()) }
            XCTAssertEqual(log.last, name)
            XCTAssertTrue(executor.appSessions(agent).isEmpty)
        }
        log = []
        let count = HelperFixtureBox(0)
        dependencies.personGate = { _, _, _, _ in
            let current = count.update { $0 += 1; return $0 }
            if current == 2 { throw Errors.make("paused") }
        }
        rebuild()
        fail("paused") { _ = try self.executor.execute(self.call()) }
        XCTAssertEqual(count.value, 2)
        XCTAssertTrue(executor.appSessions(agent).isEmpty)
    }
    func testCannotCompleteMapsToNotRespondingButOtherAXErrorsSurvive() {
        readError = AX.failure(AX.cannotComplete)
        XCTAssertThrowsError(try read()) {
            XCTAssertEqual(($0 as? HarnessError)?.name, "app_not_responding")
            XCTAssertTrue(String(describing: $0).contains("Demo"))
        }
        readError = AX.failure(AX.invalidElement)
        XCTAssertThrowsError(try read()) {
            XCTAssertEqual(($0 as? HarnessError)?.name, "accessibility_failed")
        }
    }
    func testUnexpectedReadFailureIsCaptureFailedAndFailedFirstReadIsInactive() {
        readError = CocoaError(.fileReadUnknown)
        fail("capture_failed") { _ = try self.read() }
        XCTAssertFalse(executor.appSessions(agent)[0].active)
        XCTAssertThrowsError(try executor.execute(call("click", ["element_index": 0]))) {
            XCTAssertEqual(($0 as? HarnessError)?.name, "no_session")
        }
        XCTAssertFalse(log.contains("send:click"))
    }
    func testJSONShapesEmitFalseAndScreenshotFailureStillGivesTree() throws {
        let out = try executor.execute(call("get_app_state", ["json": true, "emit": false]))
        let value = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(value["app"] as? String, "Demo")
        XCTAssertEqual((value["screenshot"] as? [String: String])?["url"], "file:///tmp/demo.jpg")
        XCTAssertTrue((value["text"] as? String)?.contains("button OK") == true)
        let only = try executor.execute(call("get_app_state", ["emit": false]))
        XCTAssertTrue(only.stdout.hasPrefix("Screenshot ("))
        screenshotError = Errors.make("screenshot_failed")
        let noShot = try executor.execute(call("get_app_state", ["json": true]))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(noShot.stdout.utf8)) as? [String: Any])
        XCTAssertTrue(object["screenshot"] is NSNull)
        _ = try executor.execute(call("click", ["element_index": 0]))
        fail("screenshot_failed") {
            _ = try self.executor.execute(self.call("click", ["x": 1, "y": 1]))
        }
    }
    func testKeepCopiesScreenshotAndPrintsProofURI() throws {
        let source = home.appendingPathComponent("shot.jpg")
        try Data("proof".utf8).write(to: source)
        dependencies.picture = { _, _ in
            Shot(path: source.path, scale: 1, origin: .zero, width: 20, height: 10)
        }
        dependencies.screenshot = Screenshot(
            folder: home.appendingPathComponent("cache"), stateDirectory: { [home = home!] in home })
        rebuild()
        let outcome = try executor.execute(call("get_app_state", ["keep": true, "json": true]))
        let value = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8)) as? [String: Any])
        let url = try XCTUnwrap((value["screenshot"] as? [String: String])?["url"])
        XCTAssertTrue(url.contains("/proof/"))
        XCTAssertEqual(try Data(contentsOf: URL(string: url)!), Data("proof".utf8))
    }
    func testActionResultNullAndFixedSentenceAndFlagsSetBeforeFailure() throws {
        try read()
        log = []
        let out = try executor.execute(call("click", ["element_index": 0]))
        XCTAssertEqual(out.stdout, HarnessExecutor.actionLine + "\n")
        XCTAssertEqual(
            log,
            [
                "resolve", "policy", "approval", "permissions", "lock", "person", "queue", "person",
                "send:click",
            ])
        let json = try executor.execute(call("click", ["element_index": 0, "json": true]))
        XCTAssertEqual(json.stdout, "null\n")
        sendError = Errors.make("paused")
        fail("paused") { _ = try self.executor.execute(self.call("click", ["element_index": 0])) }
        XCTAssertTrue(executor.appSessions(agent)[0].needsSettle)
    }
    func testActionsRequireReadAndReplacedOrQuitProcessInvalidatesNumbers() throws {
        XCTAssertThrowsError(try executor.execute(call("click", ["element_index": 0]))) {
            XCTAssertEqual(($0 as? HarnessError)?.name, "no_session")
        }
        try read()
        running = false
        XCTAssertThrowsError(try executor.execute(call("click", ["element_index": 0]))) {
            XCTAssertEqual(($0 as? HarnessError)?.name, "app_not_running")
        }
        XCTAssertFalse(executor.appSessions(agent)[0].active)
    }
    func testSettleBeforeKeysNotClicksAndReadReusesSettledCapture() throws {
        try read()
        log = []
        _ = try executor.execute(call("click", ["element_index": 0]))
        _ = try executor.execute(call("click", ["element_index": 0]))
        XCTAssertFalse(log.contains("settle"))
        _ = try executor.execute(call("press_key", ["key": "Return"]))
        XCTAssertLessThan(log.firstIndex(of: "settle")!, log.firstIndex(of: "send:press_key")!)
        log = []
        _ = try executor.execute(call("type_text", ["text": "a"]))
        XCTAssertTrue(log.contains("settle"))
        settled = makeCapture("Settled")
        log = []
        let out = try read()
        XCTAssertTrue(out.stdout.contains("Settled"))
        XCTAssertFalse(log.contains("read"))
        XCTAssertFalse(executor.appSessions(agent)[0].needsSettle)
    }
    func testSettleNilFallsBackToReadAndLaunchUsesFastPoll() throws {
        try read()
        _ = try executor.execute(call("click", ["element_index": 0]))
        log = []
        try read()
        XCTAssertLessThan(log.firstIndex(of: "settle")!, log.firstIndex(of: "read")!)
        try executor.letGo(agent, withAppQueue: { _, work in try work() })
        running = false
        log = []
        try read()
        XCTAssertLessThan(log.firstIndex(of: "launch")!, log.firstIndex(of: "enable")!)
        XCTAssertTrue(log.contains("settleFresh"))
    }
    func testEnableAsksOnceAndWarmsChromium() throws {
        switchedOn = true
        try read()
        XCTAssertTrue(log.contains("askOnce"))
        XCTAssertFalse(log.contains("settle"))
        log = []
        try read()
        XCTAssertFalse(log.contains("askOnce"))
        try executor.letGo(agent, withAppQueue: { _, work in try work() })
        var appSystem = dependencies.apps.system
        appSystem.info = { _ in ["NSPrincipalClass": Apps.chromiumClass] }
        dependencies.apps = Apps(system: appSystem)
        rebuild()
        log = []
        try read()
        XCTAssertLessThan(
            try XCTUnwrap(log.firstIndex(of: "askOnce")),
            try XCTUnwrap(log.firstIndex(of: "settle")))
    }
    func testRefetchIgnoresValueOnlyForSetValue() throws {
        let world = world
        dependencies.resolveElement = { revisions, index, reread, ignore in
            world.recordIgnore(ignore)
            return try revisions.resolve(index, reread: reread, ignoreValue: ignore)
        }
        rebuild()
        try read()
        _ = try executor.execute(call("set_value", ["element_index": 0, "value": "x"]))
        _ = try executor.execute(call("click", ["element_index": 0]))
        XCTAssertEqual(seenIgnore, [true, false])
    }
    func testPointCoordinatesUseLastShotAndIndexWinsOverInvalidPoint() throws {
        try read()
        _ = try executor.execute(call("click", ["x": 200, "y": 100]))
        if case .point(let point)? = targets.first {
            XCTAssertEqual(point, CGPoint(x: 200, y: 100))
        } else {
            XCTFail()
        }
        _ = try executor.execute(
            call("drag", ["from_x": 0, "from_y": 0, "to_x": 800, "to_y": 600]))
        if case .point(let point) = targets[1] {
            XCTAssertEqual(point, CGPoint(x: 500, y: 350))
        } else {
            XCTFail()
        }
        _ = try executor.execute(call("click", ["element_index": 0, "x": "bad", "y": "bad"]))
        if case .line = targets[0] {} else { XCTFail() }
    }
    func testDeadlineMarginsRejectHoldsAndTypingBeforeSending() throws {
        try read()
        for (name, args) in [
            ("press_key", ["key": "a", "duration": "25"]),
            ("click", ["element_index": "0", "click_count": "3", "duration": "10"]),
            ("type_text", ["text": String(repeating: "x", count: 20000)]),
        ] {
            log = []
            fail("request_timed_out") {
                _ = try self.executor.execute(
                    self.call(name, args, deadline: name == "type_text" ? 1005 : 1020))
            }
            XCTAssertFalse(log.contains("send:\(name)"))
        }
        _ = try executor.execute(call("press_key", ["key": "a", "duration": "15"], deadline: 1020))
        abandoned = true
        fail("request_timed_out") {
            _ = try self.executor.execute(self.call("click", ["element_index": 0]))
        }
    }
    func testStillWantedIsRepeatedAfterSettleAndLookup() throws {
        let world = world
        dependencies.resolveElement = { revisions, index, reread, ignore in
            world.now = 1119
            return try revisions.resolve(index, reread: reread, ignoreValue: ignore)
        }
        rebuild()
        try read()
        fail("request_timed_out") {
            _ = try self.executor.execute(self.call("click", ["element_index": 0]))
        }
        XCTAssertFalse(log.contains("send:click"))
    }
    func testLimitsAndValidationOrderWithoutTouchingApps() {
        let cases: [(String, [String: Any])] = [
            ("click", ["element_index": 0, "click_count": 11]),
            ("click", ["element_index": 0, "duration": 30, "click_count": 5]),
            ("click", ["x": true, "y": 2]), ("click", ["element_index": 1.5]),
            ("click", ["element_index": 0, "mouse_button": 3]),
            ("press_key", ["key": "a", "duration": "nan"]),
            ("press_key", ["key": "a", "duration_ms": 30001]),
            ("type_text", ["text": String(repeating: "x", count: 20001)]),
            ("set_value", ["element_index": 0]),
            ("scroll", ["pages": "inf"]), ("scroll", ["pages": -1]),
            ("scroll", ["element_index": 0, "direction": "bad"]),
            ("select_text", ["element_index": 0, "selection_type": "bad"]), ("paste", [:]),
        ]
        for (name, args) in cases {
            XCTAssertThrowsError(try executor.execute(call(name, args)), "\(name) \(args)")
            XCTAssertTrue(log.isEmpty)
        }
    }
    func testFiniteNumbersButtonsAndHoldAliases() throws {
        for value: Any in [true, false, "nan", Double.infinity, NSNull()] {
            XCTAssertNil(HarnessExecutor.number(value))
        }
        XCTAssertEqual(HarnessExecutor.integer("2.0"), 2)
        XCTAssertNil(HarnessExecutor.integer("2.5"))
        for (name, button) in HarnessExecutor.buttons {
            XCTAssertEqual(try HarnessExecutor.button(name.uppercased()), button)
        }
        XCTAssertEqual(try HarnessExecutor.hold(["duration_ms": "1500"]), 1.5)
        XCTAssertEqual(try HarnessExecutor.hold(["duration": "2", "duration_ms": "1500"]), 2)
    }
    func testSlowTypingLimitAndUnicodeScalarCount() throws {
        let world = world
        dependencies.resolve = { _ in
            var t = world.target
            t.bundleID = "com.apple.ScreenContinuity"
            return t
        }
        rebuild()
        try read()
        XCTAssertThrowsError(
            try executor.execute(call("type_text", ["text": String(repeating: "x", count: 3001)]))
        ) { XCTAssertTrue(String(describing: $0).contains("3000")) }
        _ = try executor.execute(call("type_text", ["text": String(repeating: "x", count: 3000)]))
    }
    func testEnvironmentDiffZeroPrintsFullStateAndDoesNotAlterAgentEnvironment() throws {
        try read()
        let full = try executor.execute(call("get_app_state", env: ["TERM_LLM_COMPUTER_DIFF": "0"]))
        XCTAssertTrue(full.stdout.contains("button OK"))
        XCTAssertTrue(Wire.passed(["TERM_LLM_COMPUTER_DIFF": "0"])["TERM_LLM_COMPUTER_DIFF"] == "0")
    }
    func testLetGoDropsSessionsResetsWatchersAndCancellationSignalSemantics() throws {
        try read()
        let app = executor.appSessions(agent)[0]
        sessions.turnStarted(agent)
        let before = sessions.cancellationGeneration(agent)
        _ = try executor.execute(call("turn-ended", ["cancel": false]))
        XCTAssertFalse(sessions.hasEnded(agent))
        XCTAssertEqual(sessions.cancellationGeneration(agent), before)
        XCTAssertTrue(executor.appSessions(agent).isEmpty)
        XCTAssertNil(app.watching)
        XCTAssertNil(app.revisions?.last)
        XCTAssertTrue(log.contains("cleanupQueue"))
        XCTAssertTrue(ax.observations.allSatisfy(\.stopped))
        try read()
        _ = try executor.execute(call("turn-ended", ["cancel": true]))
        XCTAssertTrue(sessions.hasEnded(agent))
        XCTAssertEqual(sessions.cancellationGeneration(agent), before + 1)
        _ = try executor.execute(call("turn-started"))
        XCTAssertFalse(sessions.hasEnded(agent))
    }
    func testReapUsesSameLetGoAndOtherAgentsAreIsolated() throws {
        try read()
        let other = sessions.agent(peerPID: 2, env: ["TERM_LLM_SESSION_ID": "other"])
        _ = try executor.execute(call(other: other))
        XCTAssertEqual(executor.appSessions(other).count, 1)
        executor.agentExited(agent, withAppQueue: { _, work in try work() })
        XCTAssertTrue(executor.appSessions(agent).isEmpty)
        XCTAssertEqual(executor.appSessions(other).count, 1)
        try executor.letGo(other, withAppQueue: { _, work in try work() })
    }
    func testListAppsDoctorHelpSkillBypassEveryGateAndJSONValues() throws {
        let list = try executor.execute(call("list_apps", ["json": true]))
        XCTAssertTrue(try JSONSerialization.jsonObject(with: Data(list.stdout.utf8)) is [Any])
        XCTAssertTrue(log.isEmpty)
        var calls = Permissions.Calls()
        calls.granted = { _ in false }
        calls.canCapture = { false }
        calls.request = { _ in XCTFail("No grant requests") }
        calls.open = { _ in XCTFail("No panes") }
        dependencies.permissions = Permissions(calls: calls)
        rebuild()
        let doctor = try executor.execute(call("doctor", ["json": true]))
        XCTAssertTrue(
            try JSONSerialization.jsonObject(with: Data(doctor.stdout.utf8)) is [String: Any])
        let help = try executor.execute(call("help", ["json": true]))
        XCTAssertTrue(
            try JSONSerialization.jsonObject(
                with: Data(help.stdout.utf8), options: .fragmentsAllowed)
                is String)
        XCTAssertEqual(try executor.execute(call("skill")).stdout, ComputerUseSkill.text + "\n")
        XCTAssertTrue(log.isEmpty)
    }
    func testPermissionGateIsPassiveAndNeverRequestsGrants() {
        var calls = Permissions.Calls()
        calls.granted = { _ in false }
        calls.canCapture = { false }
        calls.request = { _ in XCTFail("No grant requests") }
        calls.open = { _ in XCTFail("No panes") }
        dependencies.permissions = Permissions(calls: calls)
        dependencies.permissionsGate = nil
        rebuild()
        XCTAssertThrowsError(try read()) {
            XCTAssertTrue(String(describing: $0).contains("Accessibility"))
        }
        XCTAssertFalse(log.contains("lock"))
    }
    func testPanelServiceUsesOnlyThisAgentsWatchedAppsBeforePolicy() throws {
        let world = world
        try read()
        ax.window.attrs["AXIdentifier"] = "save-panel"
        dependencies.resolve = { _ in
            AppTarget(path: "/System/Panel.xpc", bundleID: Limits.panelService, name: "Panel")
        }
        dependencies.decide = { _, target in
            XCTAssertEqual(target.path, world.target.path)
            world.record("ownerPolicy")
            return PolicyDecision(
                decision: .allowed, risk: .low, allowPersistent: false, warning: nil)
        }
        // Reuse current sessions with the same executor dependencies: another
        // executor intentionally has none and must reject the raw service.
        let blank = HarnessExecutor(dependencies: dependencies)
        XCTAssertThrowsError(try blank.execute(call())) {
            XCTAssertEqual(($0 as? HarnessError)?.name, "no_such_app")
        }
    }
    func testBlockedPageEndsSessionBeforePictureOrAnotherActionAndSettledCaptureIsChecked() throws {
        var appSystem = dependencies.apps.system
        appSystem.info = { _ in ["CFBundleURLTypes": [["CFBundleURLSchemes": ["http"]]]] }
        dependencies.apps = Apps(system: appSystem)
        try Data("blocked_urls = [\"bad.example\"]\n".utf8).write(
            to: home.appendingPathComponent("user"))
        rebuild()
        try read()
        _ = try executor.execute(call("press_key", ["key": "Return"]))
        XCTAssertTrue(executor.appSessions(agent)[0].pageUnchecked)
        settled = makeCapture("Later")
        settled?.url = "https://bad.example/path"
        log = []
        fail("blocked_url") {
            _ = try self.executor.execute(self.call("click", ["element_index": 0]))
        }
        XCTAssertTrue(log.contains("settle"))
        XCTAssertFalse(log.contains("read") || log.contains("send:click"))
        XCTAssertFalse(executor.appSessions(agent)[0].active)
        capture.url = "https://bad.example/path"
        log = []
        fail("blocked_url") { _ = try self.read() }
        XCTAssertFalse(log.contains("picture"))
    }
    func testUnblockedBrowserChainWithoutURLRulesDoesNotReadBetweenClicks() throws {
        var appSystem = dependencies.apps.system
        appSystem.info = { _ in ["CFBundleURLTypes": [["CFBundleURLSchemes": ["http"]]]] }
        dependencies.apps = Apps(system: appSystem)
        rebuild()
        try read()
        _ = try executor.execute(call("click", ["element_index": 0]))
        log = []
        _ = try executor.execute(call("click", ["element_index": 0]))
        XCTAssertFalse(log.contains("settle") || log.contains("read"))
    }
    func testListAppsFailuresHaveNativePrefixAndEmitFalseStillReturnsRowsAsJSON() throws {
        let world = world
        dependencies.listApps = { _ in throw Errors.serverError("catalog unavailable") }
        rebuild()
        XCTAssertThrowsError(try executor.execute(call("list_apps"))) {
            XCTAssertTrue(String(describing: $0).hasPrefix("Native apps: "))
        }
        dependencies.listApps = { hosts in
            XCTAssertEqual(hosts, world.agent.hosts)
            return [["name": "Demo"]]
        }
        rebuild()
        XCTAssertEqual(try executor.execute(call("list_apps", ["emit": false])).stdout, "")
        XCTAssertEqual(
            try executor.execute(call("list_apps", ["json": true, "emit": false])).stdout,
            "[{\"name\":\"Demo\"}]\n")
    }
    func testFreshMissingWindowSettlesThenFailsWithoutTreeReadAndLateWindowUsesCapture() throws {
        let world = world
        ax.root.attrs = [:]
        XCTAssertThrowsError(try read()) {
            XCTAssertEqual(($0 as? HarnessError)?.message, Errors.make("no_windows").message)
        }
        XCTAssertTrue(log.contains("settleFresh"))
        XCTAssertFalse(log.contains("read"))
        dependencies.settle = { _, _, _, poll, _ in
            XCTAssertEqual(poll, HarnessExecutor.freshWindowPoll)
            world.ax.root.attrs["AXWindows"] = [world.ax.window.ref]
            return world.makeCapture("Late")
        }
        rebuild()
        log = []
        XCTAssertTrue(try read().stdout.contains("Late"))
        XCTAssertFalse(log.contains("read"))
    }
    func testSuccessfulPanelServiceResolutionUsesWatchingOwnerAndAnotherAgentCannotBorrowIt() throws
    {
        let normal = target
        let panel = AppTarget(
            path: "/System/Panel.xpc", bundleID: Limits.panelService, name: "Panel")
        dependencies.resolve = { name in name == "Panel" ? panel : normal }
        rebuild()
        try read()
        ax.window.attrs["AXIdentifier"] = "save-panel"
        _ = try executor.execute(call("get_app_state", ["app": "Panel"]))
        XCTAssertEqual(queuePath, normal.path)
        let other = sessions.agent(peerPID: 3, env: ["TERM_LLM_SESSION_ID": "other"])
        XCTAssertThrowsError(
            try executor.execute(call("get_app_state", ["app": "Panel"], other: other))
        ) { XCTAssertEqual(($0 as? HarnessError)?.name, "no_such_app") }
    }
    func testDeadProcessReapingCallsExecutorLetGoUnderCleanupFIFO() throws {
        let alive = HelperFixtureBox(true)
        let process = ProcessIdentity(pid: 10, parent: 1, path: "/bin/term-llm", started: 12)
        let registry = Sessions(process: { pid in
            if pid == 11 { return .init(pid: 11, parent: 10, path: "/bin/client", started: 14) }
            return alive.value && pid == 10 ? process : nil
        })
        let dead = registry.agent(peerPID: 11, env: [:])
        let request = ToolCallRequest(
            name: "get_app_state", arguments: ["app": "Demo"], stdin: nil, environment: [:],
            agent: dead,
            sessions: registry, cwd: "/", deadline: Date(timeIntervalSince1970: 1120),
            abandoned: { false }, withAppQueue: { _, work in try work() })
        _ = try executor.execute(request)
        XCTAssertEqual(executor.appSessions(dead).count, 1)
        let server = HelperServer(
            executor: executor,
            configuration: HelperConfiguration(environment: ["TERM_LLM_COMPUTER_HOME": home.path]),
            sessions: registry)
        alive.value = false
        server.reapSessions()
        XCTAssertTrue(executor.appSessions(dead).isEmpty)
        XCTAssertTrue(ax.observations.allSatisfy(\.stopped))
        server.stop()
    }

    func testAppSessionInsertionOrderAndCancelClosureArePreserved() throws {
        let world = world
        var second = target
        second.path = "/Applications/Second.app"
        second.bundleID = "dev.second"
        let secondTarget = second
        dependencies.resolve = { name in name == "Second" ? secondTarget : world.target }
        rebuild()
        try read()
        XCTAssertThrowsError(
            try executor.execute(call("click", ["app": "Second", "element_index": 0])))
        XCTAssertEqual(
            executor.appSessions(agent).map { $0.target.path }, [target.path, second.path])
        abandoned = true
        XCTAssertTrue(executor.appSessions(agent)[0].cancel())
    }
    func testAgentCollectionsMutateAtomicallyAcrossAppAndPanelWorkers() {
        let agent = agent!
        DispatchQueue.concurrentPerform(iterations: 500) { index in
            agent.denied.insert("app-\(index)")
            agent.instructed.insert("bundle-\(index)")
            agent.cancels += 1
        }
        XCTAssertEqual(agent.denied.count, 500)
        XCTAssertEqual(agent.instructed.count, 500)
        XCTAssertEqual(agent.cancels, 500)
    }
    func testApprovalSessionKeysFailClosedWhenNumericIdentityIsMalformed() {
        for key in ["", "12", "12:", "12:no", "12:nan", "999999999999999:1"] {
            XCTAssertFalse(HarnessExecutor.sessionAlive(key), key)
        }
        XCTAssertTrue(HarnessExecutor.sessionAlive("term-llm-session"))
        XCTAssertTrue(HarnessExecutor.sessionAlive("named:session"))
    }

}
