import ComputerUseCore
import ComputerUseSystem
import Foundation
import os
import XCTest

@testable import ComputerUseHelper

// This suite never constructs a server, starts a tap, posts an event, takes a
// power assertion, or calls shutdown. Default dependency constructors are passive
// builders; every reachable effect below is replaced before executing a call.
private func executorForbidden<T>(_ effect: String) -> T {
    XCTFail("Unexpected executor effect: \(effect)")
    fatalError("Pure executor fixture reached \(effect)")
}

private final class ExecutorLog: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [String]())
    func append(_ event: String) { state.withLock { $0.append(event) } }
    var events: [String] { state.withLock { $0 } }
}

private final class ExecutorReference: Sendable {
    private struct State: Sendable { weak var value: HarnessExecutor? }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var value: HarnessExecutor? { state.withLock { $0.value } }
    func install(_ executor: HarnessExecutor) { state.withLock { $0.value = executor } }
}

private final class ExecutorQueues: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [String: AppFIFO]())
    func run(_ path: String, _ work: () throws -> ToolOutcome) throws -> ToolOutcome {
        let queue = state.withLock { state in
            if let queue = state[path] { return queue }
            let queue = AppFIFO()
            state[path] = queue
            return queue
        }
        return try queue.run(work)
    }
}

private final class ExecutorRetirement: Sendable {
    let retired: @Sendable () -> Void
    init(_ retired: @escaping @Sendable () -> Void) { self.retired = retired }
    deinit { retired() }
}

// Intentionally non-Sendable. Its lifetime must end with its synchronous request,
// not with the AppSession's retained @Sendable cancellation predicate.
private final class ExecutorLocalPayload {
    let thread = pthread_mach_thread_np(pthread_self())
    let retired: @Sendable () -> Void
    init(_ retired: @escaping @Sendable () -> Void) { self.retired = retired }
    deinit { retired() }
}

private final class ExecutorPureElement: NSObject, Sendable {
    let pid: pid_t
    init(_ pid: pid_t) { self.pid = pid }
}

private final class ExecutorPureObservation: AXObservation {
    let onStop: @Sendable () -> Void
    init(_ onStop: @escaping @Sendable () -> Void) { self.onStop = onStop }
    func stop() { onStop() }
}

private final class ExecutorPureAX: AXBackend {
    let panels: Bool
    let onStop: (@Sendable () -> Void)?
    init(panels: Bool = false, onStop: (@Sendable () -> Void)? = nil) {
        self.panels = panels
        self.onStop = onStop
    }
    func app(pid: pid_t) -> UIElementRef { UIElementRef(ExecutorPureElement(pid)) }
    func get(_ element: UIElementRef, _ name: String) throws -> Any? {
        if name == Apps.catalyst { return false }
        if panels && name == "AXFocusedWindow" { return element }
        if panels && name == "AXIdentifier" { return "open-panel" }
        return executorForbidden("AX.get(\(name))")
    }
    func names(_ element: UIElementRef) -> [String] { executorForbidden("AX.names") }
    func getMany(_ element: UIElementRef, _ names: [String]) throws -> [Any?] { executorForbidden("AX.getMany") }
    func set(_ element: UIElementRef, _ name: String, _ value: Any) throws { executorForbidden("AX.set") as Void }
    func settable(_ element: UIElementRef, _ name: String) -> Bool { executorForbidden("AX.settable") }
    func actionNames(_ element: UIElementRef) -> [String] { executorForbidden("AX.actionNames") }
    func actionDescription(_ element: UIElementRef, _ action: String) -> String { executorForbidden("AX.actionDescription") }
    func perform(_ element: UIElementRef, _ action: String) throws { executorForbidden("AX.perform") as Void }
    func param(_ element: UIElementRef, _ name: String, _ argument: Any) -> Any? { executorForbidden("AX.param") }
    func pid(_ element: UIElementRef) throws -> pid_t { executorForbidden("AX.pid") }
    func windowID(_ element: UIElementRef) -> UInt32 { executorForbidden("AX.windowID") }
    func frame(_ element: UIElementRef) -> CGRect? { executorForbidden("AX.frame") }
    func at(_ app: UIElementRef?, x: Double, y: Double) -> UIElementRef? { executorForbidden("AX.at") }
    func alive(_ element: UIElementRef) -> Bool { executorForbidden("AX.alive") }
    func observe(pid: pid_t, element: UIElementRef, names: [String],
                 callback: @escaping @Sendable (String, UIElementRef) -> Void) throws -> AXObservation {
        guard let onStop else { return executorForbidden("AX.observe") }
        XCTAssertEqual(names, [Revisions.destroyed])
        return ExecutorPureObservation(onStop)
    }
}

private struct PureExecutorFixture: Sendable {
    static let first = AppTarget(path: "/fake/First.app", bundleID: "test.first", name: "First", pid: 101)
    static let second = AppTarget(path: "/fake/Second.app", bundleID: "test.second", name: "Second", pid: 102)
    static let third = AppTarget(path: "/fake/Third.app", bundleID: "test.third", name: "Third", pid: 103)
    static let fourth = AppTarget(path: "/fake/Fourth.app", bundleID: "test.fourth", name: "Fourth", pid: 104)
    let agent = AgentSession(key: "pure-executor")
    let sessions = Sessions(process: { _ in executorForbidden("process provider") })
    let queues = ExecutorQueues()
    let executor: HarnessExecutor

    init(configure: (inout HarnessExecutor.Dependencies) -> Void = { _ in }) {
        var d = HarnessExecutor.Dependencies()
        var apps = Apps.System()
        apps.running = { executorForbidden("running apps") }
        apps.executable = { pid in
            switch pid {
            case 101: return Self.first.path + "/Contents/MacOS/fake"
            case 102: return Self.second.path + "/Contents/MacOS/fake"
            case 103: return Self.third.path + "/Contents/MacOS/fake"
            case 104: return Self.fourth.path + "/Contents/MacOS/fake"
            default: return executorForbidden("executable")
            }
        }
        apps.regular = { _ in executorForbidden("activation policy") }
        apps.bundlePaths = { _ in executorForbidden("bundle lookup") }
        apps.named = { _ in executorForbidden("named app") }
        apps.open = { _ in executorForbidden("launch") }
        apps.frontPIDs = { executorForbidden("front windows") }
        apps.used = { executorForbidden("Spotlight") }
        apps.info = { _ in [:] }
        apps.entries = { _ in executorForbidden("app directories") }
        apps.realPath = { $0 }
        apps.expandUser = { $0 }
        apps.ownPID = { executorForbidden("own pid") }
        apps.panelServices = { executorForbidden("panel processes") }
        apps.processBundleID = { _ in executorForbidden("process bundle") }
        apps.now = { executorForbidden("app clock") }
        apps.wallTime = { executorForbidden("app wall clock") }
        apps.sleep = { _ in executorForbidden("app sleep") as Void }
        apps.keyWindow = { _ in executorForbidden("app key window") }
        d.apps = Apps(system: apps)

        var windows = Windows.System()
        windows.rows = { _, _ in executorForbidden("window server") }
        windows.associated = { _ in executorForbidden("associated windows") }
        windows.now = { executorForbidden("window clock") }
        windows.sleep = { _ in executorForbidden("window sleep") as Void }
        windows.noAttention = { _ in executorForbidden("window attention") as Void }
        d.windows = Windows(system: windows)

        let person = Person.System(
            now: { executorForbidden("person clock") },
            sleep: { _ in executorForbidden("person sleep") as Void },
            frontmostPID: { executorForbidden("frontmost app") },
            bundleOf: { _ in executorForbidden("person bundle") },
            hidIdle: { _ in executorForbidden("HID idle") },
            secureInputPID: { executorForbidden("secure input") },
            windowPID: { _ in executorForbidden("window pid") },
            canListen: { executorForbidden("listen permission") })
        let hooks = Person.Hooks(
            pointerActivity: { _ in executorForbidden("person overlay") as Void },
            shownMenu: { _ in executorForbidden("person menu") },
            post: { _, _ in executorForbidden("person event") as Void },
            later: { _, _ in executorForbidden("person scheduler") as Void })
        d.person = Person(system: person, hooks: hooks, watch: Person.Watch(
            isRunning: { false }, schedule: { _ in executorForbidden("tap scheduling") as Void },
            create: { _ in executorForbidden("tap creation") }))

        var focus = Focus.System()
        focus.frontPID = { executorForbidden("focus frontmost") }
        focus.noAttention = { _ in executorForbidden("focus attention") as Void }
        focus.post = { _, _ in executorForbidden("focus events") as Void }
        focus.freeze = { executorForbidden("freeze") as Void }
        focus.thaw = { executorForbidden("thaw") as Void }
        focus.now = { executorForbidden("focus clock") }
        focus.sleep = { _ in executorForbidden("focus sleep") as Void }
        focus.background = { _ in executorForbidden("focus worker") as Void }
        focus.personWent = { _, _ in executorForbidden("focus human query") }
        d.focus = Focus(system: focus)
        d.presence = Presence(
            enabled: { false }, now: { executorForbidden("presence clock") },
            send: { _ in executorForbidden("overlay") as Void },
            schedule: { _ in executorForbidden("UI scheduling") as Void },
            ask: { _ in executorForbidden("panel") as Void },
            withdraw: { _ in executorForbidden("panel withdrawal") as Void })
        var permissions = Permissions.Calls()
        permissions.granted = { _ in executorForbidden("permission preflight") }
        permissions.request = { _ in executorForbidden("permission request") as Void }
        permissions.open = { _ in executorForbidden("Settings") as Void }
        permissions.settingsOpen = { executorForbidden("Settings query") }
        permissions.canCapture = { executorForbidden("capture preflight") }
        permissions.time = { executorForbidden("permission clock") }
        permissions.monotonic = { executorForbidden("permission uptime") }
        permissions.sleep = { _ in executorForbidden("permission sleep") as Void }
        permissions.callOnMain = { _ in executorForbidden("main hop") as Void }
        d.permissions = Permissions(calls: permissions)
        // These URLs must never be read/written. Any callback that could lead to
        // them traps; these tests do not run screenshot/approval/policy storage.
        let unused = URL(fileURLWithPath: "/pure-executor-unused")
        d.screenshot = Screenshot(
            folder: unused, stateDirectory: { executorForbidden("screenshot directory") },
            runner: { _, _, _ in executorForbidden("screenshot process") as Void },
            sources: [{ _, _ in executorForbidden("screenshot capture") }],
            uptime: { executorForbidden("screenshot uptime") },
            appName: { _ in executorForbidden("screenshot app name") })
        d.approvals = Approvals(
            store: ApprovalStore(directory: unused),
            ask: { _ in executorForbidden("approval UI") },
            withdraw: { _ in executorForbidden("approval withdrawal") as Void },
            now: { executorForbidden("approval clock") },
            sleep: { _ in executorForbidden("approval sleep") as Void },
            alive: { _ in executorForbidden("approval process") })
        d.policy = Policy(managedFile: unused, userFile: unused,
                          appKind: { _ in executorForbidden("policy classification") })
        d.instructions = Instructions(stateDirectory: { executorForbidden("instruction files") })
        var actions = Actions.System()
        actions.apps = d.apps
        actions.windows = d.windows
        actions.focus = d.focus
        actions.presence = d.presence
        actions.pasteboard = ComputerUseSystem.Pasteboard(
            board: { executorForbidden("pasteboard") },
            stateDirectory: { executorForbidden("clipboard directory") })
        actions.checkRecipient = { _ in executorForbidden("recipient policy") as Void }
        actions.post = { _, _, _ in executorForbidden("action events") as Void }
        actions.heldFlags = { executorForbidden("held keys") }
        actions.presses = { _ in executorForbidden("key layout") }
        actions.printedText = { _ in executorForbidden("printed text") }
        actions.focusElement = { _ in executorForbidden("element focus") }
        actions.now = { executorForbidden("action clock") }
        actions.sleep = { _ in executorForbidden("action sleep") as Void }
        actions.background = { _ in executorForbidden("action worker") as Void }
        d.actions = Actions(system: actions)

        d.listApps = { _ in executorForbidden("list apps") }
        d.send = { _, _, _ in executorForbidden("send") as Void }
        d.resolveElement = { _, _, _, _ in executorForbidden("element refetch") }
        d.resolve = { name in
            switch name {
            case "First": return Self.first
            case "Second": return Self.second
            case "Third": return Self.third
            case "Fourth": return Self.fourth
            default: return executorForbidden("resolve \(name)")
            }
        }
        d.decide = { _, _ in .init(decision: .allowed, risk: .low, allowPersistent: false, warning: nil) }
        d.ensureApproval = { _, _, _, _, _ in }
        d.permissionsGate = { _, _ in }
        d.lockGate = { _ in }
        d.personGate = { _, _, _, _ in }
        d.read = { _, _, _, _ in executorForbidden("tree read") }
        d.enable = { _, _ in executorForbidden("tree enable") }
        d.disable = { _ in executorForbidden("tree disable") as Void }
        d.askOnce = { _ in executorForbidden("tree warmup") as Void }
        d.watchRevisions = { _, _ in executorForbidden("revision watch") as Void }
        d.settle = { _, _, _, _, _ in executorForbidden("settle") }
        d.picture = { _, _ in executorForbidden("picture") }
        d.now = { 0 }
        d.uptime = { 0 }
        configure(&d)
        executor = HarnessExecutor(dependencies: d)
    }

    func call(_ name: String = "press_key", app: String = "First",
              arguments: [String: Any] = [:], abandoned: @escaping @Sendable () -> Bool = { false }) -> ToolCallRequest {
        var arguments = arguments
        arguments["app"] = app
        arguments["key"] = "a"
        return ToolCallRequest(
            name: name, arguments: arguments, stdin: nil, environment: [:],
            agent: agent, sessions: sessions, cwd: "/fake", deadline: Date(timeIntervalSince1970: 100),
            abandoned: abandoned,
            withCleanupQueue: { [queues] path, work in try queues.run(path, work) },
            withAppQueue: { [queues] path, work in try queues.run(path, work) })
    }

    @discardableResult func register(_ name: String = "First") throws -> AppSession {
        // The real orchestration allocates the session, then safely rejects an
        // action without an earlier state read. No AX/Apps/Actions path is reached.
        XCTAssertThrowsError(try executor.execute(call(app: name))) { error in
            XCTAssertEqual((error as? HarnessError)?.name, Errors.make("not_active").name)
        }
        return try XCTUnwrap(executor.appSessions(agent).first { $0.target.name == name })
    }
}

final class PureExecutorOwnershipTests: XCTestCase {
    private func wait(_ semaphore: DispatchSemaphore, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(semaphore.wait(timeout: .now() + 5), .success, file: file, line: line)
    }

    func testSharedExecutorRunsDifferentAppsConcurrentlyWithoutTransferringRequests() throws {
        let firstEntered = DispatchSemaphore(value: 0), releaseFirst = DispatchSemaphore(value: 0)
        let secondDone = DispatchSemaphore(value: 0), firstDone = DispatchSemaphore(value: 0)
        let payloadRetired = DispatchSemaphore(value: 0), log = ExecutorLog()
        let fixture = PureExecutorFixture { d in
            d.send = { call, app, targets in
                XCTAssertTrue(targets.isEmpty)
                let payload = try XCTUnwrap(call.arguments["payload"] as? ExecutorLocalPayload)
                XCTAssertEqual(payload.thread, pthread_mach_thread_np(pthread_self()))
                XCTAssertEqual(app.target.name, call.arguments["app"] as? String)
                if app.target.name == "First" {
                    firstEntered.signal()
                    XCTAssertEqual(releaseFirst.wait(timeout: .now() + 5), .success)
                }
                log.append(app.target.name)
            }
        }
        try fixture.register().active = true
        try fixture.register("Second").active = true
        let backend = ExecutorPureAX()
        DispatchQueue.global().async {
            defer { firstDone.signal() }
            AX.withBackend(backend) {
                do {
                    let payload = ExecutorLocalPayload { payloadRetired.signal() }
                    let result = try fixture.executor.execute(fixture.call(arguments: ["payload": payload]))
                    XCTAssertEqual(result.stdout, HarnessExecutor.actionLine + "\n")
                } catch { XCTFail("Unexpected first action: \(error)") }
            }
        }
        wait(firstEntered)
        DispatchQueue.global().async {
            defer { secondDone.signal() }
            AX.withBackend(backend) {
                do {
                    let payload = ExecutorLocalPayload {}
                    _ = try fixture.executor.execute(fixture.call(app: "Second", arguments: ["payload": payload]))
                } catch { XCTFail("Unexpected second action: \(error)") }
            }
        }
        wait(secondDone)
        XCTAssertEqual(log.events, ["Second"], "An independent app must finish while First is blocked")
        XCTAssertEqual(firstDone.wait(timeout: .now()), .timedOut)
        releaseFirst.signal()
        wait(firstDone)
        wait(payloadRetired)
        XCTAssertEqual(log.events, ["Second", "First"])
        // The retained cancellation hook is genuinely shareable and does not keep
        // the non-Sendable payload/request envelope alive after the call returns.
        XCTAssertFalse(try XCTUnwrap(fixture.executor.appSessions(fixture.agent).first).cancel())
    }

    func testDependencyBuilderIsFrozenAndGateCallbacksCanReenterRegistry() throws {
        let reference = ExecutorReference(), log = ExecutorLog()
        let agent = AgentSession(key: "pure-executor")
        let fixture = PureExecutorFixture { d in
            d.resolve = { _ in
                let executor = try XCTUnwrap(reference.value)
                XCTAssertLessThanOrEqual(executor.appSessions(agent).count, 1)
                executor.cancel(agentKeys: [])
                log.append("resolve")
                return PureExecutorFixture.first
            }
            d.decide = { _, _ in
                log.append("policy")
                return .init(decision: .allowed, risk: .low, allowPersistent: false, warning: nil)
            }
            d.ensureApproval = { _, _, _, _, abandoned in
                XCTAssertFalse(abandoned())
                log.append("approval")
            }
            d.permissionsGate = { _, _ in log.append("permissions") }
            d.lockGate = { _ in log.append("lock") }
            d.personGate = { _, _, _, _ in log.append("person") }
            d.now = { log.append("deadline"); return 0 }
            d.uptime = {
                XCTAssertEqual(reference.value?.appSessions(agent).map(\.target.path), [PureExecutorFixture.first.path])
                log.append("uptime")
                return 7
            }
        }
        reference.install(fixture.executor)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { done.signal() }
            do { try fixture.register() } catch { XCTFail("Registration failed: \(error)") }
        }
        wait(done)
        XCTAssertEqual(log.events, ["resolve", "policy", "approval", "permissions", "lock", "person", "person", "deadline", "uptime"])
        var builder = fixture.executor.dependencies
        builder.resolve = { _ in executorForbidden("mutated builder") }
        builder.now = { executorForbidden("mutated builder clock") }
        // Value-builder mutations cannot alter the executor's immutable snapshot.
        XCTAssertEqual(try fixture.executor.dependencies.resolve?("First"), PureExecutorFixture.first)
        XCTAssertEqual(fixture.executor.dependencies.now(), 0)
        XCTAssertNotNil(builder.resolve)
    }

    func testRegistryPreservesFirstUseOrderAndPanelUsesNewestWatchingApp() throws {
        let fixture = PureExecutorFixture { d in
            let resolve = d.resolve!
            d.resolve = { name in
                if name == "Panel" {
                    return AppTarget(path: "/fake/Panel.app", bundleID: Limits.panelService, name: "Panel", pid: 199)
                }
                return try resolve(name)
            }
        }
        func assertPanelOwner(_ owner: AppSession) throws {
            try AX.withBackend(ExecutorPureAX(panels: true)) {
                XCTAssertThrowsError(try fixture.executor.execute(fixture.call(app: "Panel"))) { error in
                    XCTAssertEqual((error as? HarnessError)?.message,
                                   Errors.make("not_active", ["app": owner.target.path]).message)
                }
            }
        }
        let first = try fixture.register(), second = try fixture.register("Second")
        XCTAssertTrue(try fixture.register() === first)
        XCTAssertEqual(fixture.executor.appSessions(fixture.agent).map(\.target.path), [first.target.path, second.target.path])
        first.watching = first.target
        second.watching = second.target
        defer { first.watching = nil; second.watching = nil }
        try assertPanelOwner(second)
        XCTAssertEqual(fixture.executor.appSessions(fixture.agent).count, 2)

        let third = try fixture.register("Third"), fourth = try fixture.register("Fourth")
        third.watching = third.target
        fourth.watching = fourth.target
        defer { third.watching = nil; fourth.watching = nil }
        XCTAssertTrue(try fixture.register("Second") === second)
        XCTAssertTrue(try fixture.register("Third") === third)
        XCTAssertTrue(try fixture.register() === first)
        let expected = [first, second, third, fourth].map(\.target.path)
        XCTAssertEqual(fixture.executor.appSessions(fixture.agent).map(\.target.path), expected)
        try assertPanelOwner(fourth)
        fourth.watching = nil
        try assertPanelOwner(third)
        XCTAssertEqual(fixture.executor.appSessions(fixture.agent).map(\.target.path), expected)
        XCTAssertEqual(fixture.executor.appSessions(fixture.agent).count, 4)
    }

    func testConcurrentCleanupSnapshotCannotRetireReplacementAtSamePath() throws {
        let cleanup = ExecutorLog()
        let fixture = PureExecutorFixture { d in
            d.disable = { target in
                XCTAssertEqual(target, PureExecutorFixture.first)
                cleanup.append("disable First")
            }
        }
        let original = try fixture.register()
        original.watching = original.target
        let staleSnapshot = DispatchSemaphore(value: 0), resumeStale = DispatchSemaphore(value: 0)
        let staleDone = DispatchSemaphore(value: 0), currentDone = DispatchSemaphore(value: 0)
        let observerStopped = DispatchSemaphore(value: 0)
        let backend = ExecutorPureAX(onStop: { observerStopped.signal() })
        // Fake Windows has no registered menu/watch and Focus has no enforcers:
        // switchOff's only effects are injected disable and fake observer stop.
        // Still scope every worker's AX backend to fail fast on unexpected calls.
        defer { resumeStale.signal() }
        DispatchQueue.global().async {
            defer { staleDone.signal() }
            do {
                try AX.withBackend(backend) {
                    try fixture.executor.letGo(fixture.agent, withAppQueue: { path, work in
                        // letGo has already snapshotted A1, but has not acquired the
                        // app FIFO. A second cleanup is free to retire that identity.
                        staleSnapshot.signal()
                        XCTAssertEqual(resumeStale.wait(timeout: .now() + 5), .success)
                        return try fixture.queues.run(path, work)
                    })
                }
            } catch { XCTFail("Stale cleanup failed: \(error)") }
        }
        wait(staleSnapshot)
        DispatchQueue.global().async {
            defer { currentDone.signal() }
            do {
                try AX.withBackend(backend) {
                    try fixture.executor.letGo(fixture.agent, withAppQueue: { path, work in
                        try fixture.queues.run(path, work)
                    })
                }
            } catch { XCTFail("Current cleanup failed: \(error)") }
        }
        wait(currentDone)
        XCTAssertNil(original.watching)
        XCTAssertTrue(fixture.executor.appSessions(fixture.agent).isEmpty)
        XCTAssertEqual(cleanup.events, ["disable First"])

        let replacement = try fixture.register()
        XCTAssertFalse(replacement === original)
        replacement.watching = replacement.target
        try AX.withBackend(backend) { try replacement.revisions?.watch(replacement.target) }
        let other = try fixture.register("Second")
        let expected = [replacement.target.path, other.target.path]
        XCTAssertEqual(fixture.executor.appSessions(fixture.agent).map(\.target.path), expected)
        resumeStale.signal()
        wait(staleDone)
        let survivors = fixture.executor.appSessions(fixture.agent)
        XCTAssertTrue(survivors.first === replacement)
        XCTAssertEqual(survivors.map(\.target.path), expected, "Stale cleanup must preserve replacement insertion order")
        XCTAssertEqual(replacement.watching, replacement.target)
        XCTAssertEqual(observerStopped.wait(timeout: .now()), .timedOut)
        XCTAssertEqual(cleanup.events, ["disable First"], "A1's late cleanup cannot switch off A2")

        // A2 must remain discoverable by later cleanup, not be silently removed
        // from the registry with its watcher/observation still live.
        try AX.withBackend(backend) {
            try fixture.executor.letGo(fixture.agent, withAppQueue: { path, work in
                try fixture.queues.run(path, work)
            })
        }
        XCTAssertNil(replacement.watching)
        XCTAssertTrue(fixture.executor.appSessions(fixture.agent).isEmpty)
        wait(observerStopped)
        XCTAssertEqual(cleanup.events, ["disable First", "disable First"])
    }

    func testRegistryRetirementReleasesCancellationAndObserverOutsideStateLock() throws {
        // Lifetime invariant coverage, also satisfied by the prior snapshot-based
        // cleanup: final teardown may follow the loop/FIFO work. This is not a
        // negative control for the new replacement-identity retirement guard.
        let fixture = PureExecutorFixture(), reference = ExecutorReference()
        reference.install(fixture.executor)
        let captureRetired = DispatchSemaphore(value: 0), observerStopped = DispatchSemaphore(value: 0)
        let agent = fixture.agent
        let backend = ExecutorPureAX(onStop: {
            XCTAssertTrue(reference.value?.appSessions(agent).isEmpty == true)
            reference.value?.cancel(agentKeys: [])
            observerStopped.signal()
        })
        weak var retiredApp: AppSession?
        do {
            let app = try fixture.register()
            retiredApp = app
            let capture = ExecutorRetirement {
                XCTAssertTrue(reference.value?.appSessions(agent).isEmpty == true)
                captureRetired.signal()
            }
            app.cancel = { [capture] in withExtendedLifetime(capture) { false } }
            try AX.withBackend(backend) { try app.revisions?.watch(app.target) }
        }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { done.signal() }
            do { try fixture.executor.letGo(agent, withAppQueue: { path, work in try fixture.queues.run(path, work) }) }
            catch { XCTFail("Retirement failed: \(error)") }
        }
        wait(done)
        wait(captureRetired)
        wait(observerStopped)
        XCTAssertNil(retiredApp)
        XCTAssertTrue(fixture.executor.appSessions(agent).isEmpty)
        let replacement = try fixture.register()
        XCTAssertEqual(fixture.executor.appSessions(agent).map(\.target.path), [replacement.target.path])
        XCTAssertFalse(replacement.active)
    }

    func testFIFOQueuedCancellationRemovesHeadAndPreservesSurvivorArrivalOrder() {
        let fifo = AppFIFO(), log = ExecutorLog(), cancelled = OSAllocatedUnfairLock(initialState: false)
        let ownerEntered = DispatchSemaphore(value: 0), releaseOwner = DispatchSemaphore(value: 0)
        let headQueued = DispatchSemaphore(value: 0), headDone = DispatchSemaphore(value: 0)
        let secondQueued = DispatchSemaphore(value: 0), secondEntered = DispatchSemaphore(value: 0)
        let releaseSecond = DispatchSemaphore(value: 0), thirdQueued = DispatchSemaphore(value: 0)
        let thirdDone = DispatchSemaphore(value: 0), group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                try fifo.run {
                    log.append("owner")
                    ownerEntered.signal()
                    XCTAssertEqual(releaseOwner.wait(timeout: .now() + 5), .success)
                }
            } catch { XCTFail("Owner failed: \(error)") }
        }
        wait(ownerEntered)
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave(); headDone.signal() }
            do {
                try fifo.run(abandoned: {
                    headQueued.signal()
                    return cancelled.withLock { $0 }
                }) { log.append("cancelled work must not run") }
                XCTFail("Cancelled waiter must throw")
            } catch {
                XCTAssertEqual((error as? HarnessError)?.name, Errors.make("request_timed_out").name)
            }
        }
        wait(headQueued)
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                try fifo.run(abandoned: { secondQueued.signal(); return false }) {
                    log.append("second")
                    secondEntered.signal()
                    XCTAssertEqual(releaseSecond.wait(timeout: .now() + 5), .success)
                }
            } catch { XCTFail("Second failed: \(error)") }
        }
        wait(secondQueued)
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave(); thirdDone.signal() }
            do {
                try fifo.run(abandoned: { thirdQueued.signal(); return false }) { log.append("third") }
            } catch { XCTFail("Third failed: \(error)") }
        }
        wait(thirdQueued)
        cancelled.withLock { $0 = true }
        wait(headDone)
        XCTAssertEqual(log.events, ["owner"])
        releaseOwner.signal()
        wait(secondEntered)
        XCTAssertEqual(thirdDone.wait(timeout: .now() + 0.05), .timedOut)
        releaseSecond.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(log.events, ["owner", "second", "third"])
    }

    func testWaitingAbandonedCallbackAllowsReentrantBookkeepingAndIndependentApp() {
        let fifo = AppFIFO(), otherApp = AppFIFO(), log = ExecutorLog()
        let ownerEntered = DispatchSemaphore(value: 0), releaseOwner = DispatchSemaphore(value: 0)
        let predicateEntered = DispatchSemaphore(value: 0), releasePredicate = DispatchSemaphore(value: 0)
        let headDone = DispatchSemaphore(value: 0), reentrantDone = DispatchSemaphore(value: 0)
        let independentDone = DispatchSemaphore(value: 0), tailQueued = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                try fifo.run {
                    ownerEntered.signal()
                    XCTAssertEqual(releaseOwner.wait(timeout: .now() + 5), .success)
                    log.append("owner")
                }
            } catch { XCTFail("Owner failed: \(error)") }
        }
        wait(ownerEntered)
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave(); headDone.signal() }
            do {
                try fifo.run(abandoned: {
                    // The predicate itself initiates and joins a reentrant queue
                    // call. Bound the wait so the old under-condition predicate
                    // fails an assertion rather than deadlocking this worker.
                    group.enter()
                    DispatchQueue.global().async {
                        defer { group.leave(); reentrantDone.signal() }
                        do {
                            try fifo.run(abandoned: { true }) {
                                executorForbidden("reentrant cancelled work") as Void
                            }
                            XCTFail("Reentrant cancelled waiter must throw")
                        } catch {
                            XCTAssertEqual((error as? HarnessError)?.name, Errors.make("request_timed_out").name)
                        }
                    }
                    XCTAssertEqual(reentrantDone.wait(timeout: .now() + 2), .success)
                    predicateEntered.signal()
                    XCTAssertEqual(releasePredicate.wait(timeout: .now() + 5), .success)
                    return true
                }) { executorForbidden("cancelled head work") as Void }
                XCTFail("Cancelled head must throw")
            } catch {
                XCTAssertEqual((error as? HarnessError)?.name, Errors.make("request_timed_out").name)
            }
        }
        wait(predicateEntered)
        // The predicate remains blocked after successful reentry. Both an
        // independent app and another ticket on this app remain responsive.
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave(); independentDone.signal() }
            do { try otherApp.run { log.append("independent") } }
            catch { XCTFail("Independent app failed: \(error)") }
        }
        wait(independentDone)
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                try fifo.run(abandoned: { tailQueued.signal(); return false }) { log.append("tail") }
            } catch { XCTFail("Tail failed: \(error)") }
        }
        wait(tailQueued)
        XCTAssertEqual(log.events, ["independent"])
        releasePredicate.signal()
        wait(headDone)
        releaseOwner.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(log.events, ["independent", "owner", "tail"])
    }
}
