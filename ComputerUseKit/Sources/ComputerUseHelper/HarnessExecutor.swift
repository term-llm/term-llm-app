import ComputerUseCore
import ComputerUseSystem
import CoreGraphics
import Foundation
import os

/// The only module that knows the order of a call. The other modules do their
/// single step when asked; none of them chooses the tool execution order.
public final class HarnessExecutor: ToolExecutor {
    public static let actionLine = "Done. Call `get_app_state` to see the new state of the UI."
    public static let settleBeforeKeys: Set<String> = ["press_key", "type_text"]
    public static let refetchIgnoresValue: Set<String> = ["set_value"]
    public static let freshWindowPoll = 0.05, deadlineMargin = 1.0, maxHold = 30.0
    public static let maxClicks = 10, maxText = 20_000
    public static let buttons = [
        "l": 0, "left": 0, "0": 0, "r": 1, "right": 1, "1": 1, "m": 2, "middle": 2, "2": 2,
    ]
    public static let directions = [
        "u": "up", "up": "up", "d": "down", "down": "down", "l": "left", "left": "left",
        "r": "right",
        "right": "right",
    ]

    /// Execution seams, not alternate orchestration. Fakes replace effects while
    /// exercising exactly the same order, state machine and argument validation.
    /// A value builder copied into immutable executor storage. Stored callbacks
    /// may be called concurrently; nested work/read/cancellation arguments are
    /// synchronous and nonescaping, not request transfers to another worker.
    public struct Dependencies: Sendable {
        public var apps = Apps.shared
        public var windows = Windows.shared
        public var person = Person.shared
        public var focus = Focus.shared
        public var presence = Presence.shared
        public var permissions = Permissions()
        public var screenshot = Screenshot()
        public var approvals = Approvals(alive: { HarnessExecutor.sessionAlive($0) })
        public var policy = Policy(appKind: { Apps.shared.kind($0) })
        public var instructions = Instructions()
        public var actions = Actions()
        public var listApps: (@Sendable (Set<String>) throws -> [[String: Any]])?
        public var send: (@Sendable (ToolCallRequest, AppSession, [Actions.Target]) throws -> Void)?
        public var resolveElement: @Sendable (Revisions, Int, () throws -> Capture, Bool) throws -> Line = {
            try $0.resolve($1, reread: $2, ignoreValue: $3)
        }
        public var resolve: (@Sendable (String) throws -> AppTarget)?
        public var decide: (@Sendable (AgentSession, AppTarget) throws -> PolicyDecision)?
        public var ensureApproval:
            (@Sendable (AgentSession, AppTarget, PolicyDecision, TimeInterval, () -> Bool) throws -> Void)?
        public var permissionsGate: (@Sendable (TimeInterval, () -> Bool) throws -> Void)?
        public var lockGate: @Sendable (Bool) throws -> Void = { try LockScreen.gate(stateRead: $0) }
        public var personGate: (@Sendable (AgentSession, AppTarget, Bool, () -> Bool) throws -> Void)?
        public var read:
            @Sendable (AppTarget, ComputerUseCore.WindowRef, AppKind, UIElementRef?) throws -> Capture = {
                try Tree.read($0, $1, $2, menu: $3)
            }
        public var enable: @Sendable (AppTarget, AppKind) -> Bool = { Tree.enable($0, $1) }
        public var disable: @Sendable (AppTarget) -> Void = { Tree.disable($0) }
        public var askOnce: @Sendable (UIElementRef) throws -> Void = { try Tree.askOnce($0) }
        public var watchRevisions: @Sendable (Revisions, AppTarget) throws -> Void = { try $0.watch($1) }
        public var settle:
            @Sendable (
                AppTarget, AppKind, (ComputerUseCore.WindowRef) throws -> Capture, TimeInterval?,
                () -> Bool
            )
                throws -> Capture? = { target, kind, read, poll, abandoned in
                    try Settle.wait(
                        target: target, kind: kind, read: read, poll: poll, abandoned: abandoned)
                }
        public var picture: (@Sendable (AppTarget, ComputerUseCore.WindowRef) throws -> Shot)?
        public var now: @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
        public var uptime: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        public init() {}
    }
    public let dependencies: Dependencies
    private struct State: Sendable {
        var apps: [String: [String: AppSession]] = [:]
        // Python dictionaries preserve insertion order. Panel ownership searches
        // apps already read newest-first; Dictionary.values is not enough.
        var appOrder: [String: [String]] = [:]
    }
    // Registry ownership only. App FIFOs, not this lock, coordinate multi-step
    // execution. No injected callback, SDK operation or retirement runs here.
    private let state = OSAllocatedUnfairLock(initialState: State())
    public init(dependencies: Dependencies = .init()) { self.dependencies = dependencies }
    private var d: Dependencies { dependencies }
    public static func sessionAlive(_ key: String) -> Bool {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        guard let first = parts.first, !first.isEmpty else { return false }
        if !first.allSatisfy(\.isNumber) { return true }  // explicitly named sessions
        guard parts.count == 2, let pid = Int32(first), pid > 0,
            let born = Double(parts[1]), born.isFinite
        else { return false }
        return ProcessIdentity.lookup(pid)?.started == born
    }
    public func appSessions(_ agent: AgentSession) -> [AppSession] {
        state.withLock { state in
            state.appOrder[agent.key, default: []].compactMap { state.apps[agent.key]?[$0] }
        }
    }
    private func session(_ agent: AgentSession, _ target: AppTarget) -> AppSession {
        if let found = state.withLock({ $0.apps[agent.key]?[target.path] }) { return found }
        let app = AppSession(agent: agent, target: target)
        app.revisions = Revisions()
        // Construction and release of any unused candidate stay outside the
        // registry lock, even if a future initializer/deinitializer does work.
        return withExtendedLifetime(app) {
            state.withLock { state in
                if let found = state.apps[agent.key]?[target.path] { return found }
                state.apps[agent.key, default: [:]][target.path] = app
                state.appOrder[agent.key, default: []].append(target.path)
                return app
            }
        }
    }
    public static func number(_ value: Any?) -> Double? {
        guard let value, CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID(),
            let n = Double(String(describing: value)), n.isFinite
        else { return nil }
        return n
    }
    public static func integer(_ value: Any?) -> Int? {
        guard let n = number(value), n.rounded() == n, n >= Double(Int.min), n < Double(Int.max)
        else {
            return nil
        }
        return Int(n)
    }
    private func index(_ a: [String: Any]) throws -> Int {
        guard let n = Self.integer(a["element_index"]) else { throw Usage.error("element_index") }
        return n
    }
    private func point(
        _ a: [String: Any], _ x: String = "x", _ y: String = "y", _ text: String = "coordinate"
    ) throws -> CGPoint {
        guard let x = Self.number(a[x]), let y = Self.number(a[y]) else { throw Usage.error(text) }
        return CGPoint(x: x, y: y)
    }
    private enum Target {
        case index(Int)
        case point(CGPoint)
    }
    private func target(_ a: [String: Any]) throws -> Target {
        try a["element_index"] == nil ? .point(point(a)) : .index(index(a))
    }
    public static func button(_ value: Any) throws -> Int {
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            guard [0.0, 1, 2].contains(n.doubleValue) else {
                throw Usage.error("mouse_button_number")
            }
            return n.intValue
        }
        guard
            let b = buttons[
                String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()]
        else { throw Usage.error("mouse_button") }
        return b
    }
    public static func hold(_ a: [String: Any]) throws -> Double? {
        let seconds: Double?
        if a["duration"] != nil {
            seconds = number(a["duration"])
            if seconds == nil { throw Usage.error("finite_duration") }
        } else if a["duration_ms"] != nil {
            seconds = number(a["duration_ms"]).map { $0 / 1000 }
        } else {
            return nil
        }
        guard let seconds, seconds >= 0, seconds <= maxHold else { throw Usage.error("duration") }
        return seconds
    }
    public func stillWanted(_ call: ToolCallRequest, planned: Double = 0) throws {
        // Do not start effects that would finish after the client has given up:
        // it wouldn't know they happened and would repeat them.
        if d.now() + planned >= call.deadline.timeIntervalSince1970 - Self.deadlineMargin
            || call.abandoned()
        {
            throw Errors.make("request_timed_out")
        }
    }
    private func withSession(
        _ call: ToolCallRequest, stateRead: Bool,
        work: (AppSession, AppTarget) throws -> ToolOutcome
    ) throws -> ToolOutcome {
        let a = call.arguments
        let agent = call.agent
        guard let identifier = a["app"] as? String,
            !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw Usage.error("app") }
        if call.sessions.hasEnded(agent) { throw Errors.make("turn_ended") }
        var target = try d.resolve?(identifier) ?? d.apps.resolve(identifier)
        if target.bundleID == Limits.panelService {
            target = try d.apps.panelOwner(appSessions(agent).compactMap(\.watching))
        }
        let policy = try d.decide?(agent, target) ?? d.policy.decide(agent: agent, target: target)
        if let ensureApproval = d.ensureApproval {
            try ensureApproval(
                agent, target, policy, call.deadline.timeIntervalSince1970, call.abandoned)
        } else {
            try d.approvals.ensure(
                agent: agent, target: target, policy: policy,
                deadline: call.deadline.timeIntervalSince1970,
                abandoned: call.abandoned)
        }
        if let gate = d.permissionsGate {
            try gate(call.deadline.timeIntervalSince1970, call.abandoned)
        } else {
            try d.permissions.gate(
                deadline: call.deadline.timeIntervalSince1970, abandoned: call.abandoned,
                requestUI: false)
        }
        try d.lockGate(stateRead)
        func personGate() throws {
            if let gate = d.personGate {
                try gate(agent, target, stateRead, call.abandoned)
            } else {
                try d.person.gate(
                    agent: agent, target: target, stateRead: stateRead, abandoned: call.abandoned)
            }
        }
        try personGate()
        return try call.withAppQueue(target.path) {
            // A long queue wait lets the person take over, or the client disappear.
            try personGate()
            try stillWanted(call)
            let app = session(agent, target)
            let began = d.uptime()
            let abandoned = call.abandoned
            let person = d.person
            // Retain only cancellation, not the request's argv/text/other effects.
            app.cancel = { [abandoned, person, target, began] in
                abandoned() || person.interrupted(target, since: began)
            }
            do { return try work(app, target) } catch let error as HarnessError {
                if error.message == AX.failure(AX.cannotComplete).message {
                    throw Errors.make("not_responding", ["app_name": target.name])
                }
                throw error
            }
        }
    }
    private func reader(_ target: AppTarget, _ kind: AppKind) -> (ComputerUseCore.WindowRef) throws
        ->
        Capture
    {
        { window in
            do {
                return try self.d.read(target, window, kind, self.d.windows.openMenu(target))
            } catch let
                error as HarnessError
            { throw error } catch { throw Errors.make("capture_failed") }
        }
    }
    private func hasWindow(_ target: AppTarget) throws -> Bool {
        do {
            _ = try d.windows.keyWindow(target)
            return true
        } catch let error as HarnessError {
            if error.message == Errors.make("no_windows").message { return false }
            throw error
        }
    }
    public func switchOff(_ app: AppSession) {
        let target = app.watching
        app.watching = nil
        guard let target else { return }
        // A left-open background menu would take the person's next keys. Each
        // cleanup is independent so a failure cannot skip the remaining releases.
        try? d.actions.cancelMenu(app)
        d.focus.release(target)
        d.disable(target)
        d.windows.unwatch(target)
        app.revisions?.reset()
    }
    private func checkPage(_ app: AppSession, _ capture: Capture) throws {
        do { try d.policy.checkURL(capture.url) } catch {
            app.active = false
            throw error
        }
        app.pageUnchecked = false
    }
    private func readState(_ call: ToolCallRequest, _ app: AppSession, _ initial: AppTarget) throws
        -> (String, Result<Shot, HarnessError>)
    {
        let target: AppTarget
        let launched: Bool
        do {
            target = try d.apps.running(initial)
            launched = false
        } catch let error as HarnessError {
            if error.name != Errors.make("app_not_running").name { throw error }
            target = try d.apps.launch(initial, abandoned: call.abandoned)
            launched = true
        }
        let kind = d.apps.kind(target)
        var switchedOn = false
        if app.watching != target {
            switchOff(app)
            switchedOn = d.enable(target, kind)
            try d.windows.watch(target)
            if let revisions = app.revisions { try d.watchRevisions(revisions, target) }
            app.target = target
            app.watching = target
        }
        let read = reader(target, kind)
        let fresh = try launched || !hasWindow(target)
        if switchedOn && !fresh {
            if let w = try? d.windows.keyWindow(target) { try? d.askOnce(w.element) }
        }
        var capture: Capture?
        // Chromium's tree warms for hundreds of ms after enabling accessibility;
        // an immediate Electron read can omit both the page URL and its iframe.
        if app.needsSettle || fresh || (switchedOn && (kind.electron || kind.chromium)) {
            app.needsSettle = false  // clear before waiting: another action may set it
            capture = try d.settle(
                target, kind, read, fresh ? Self.freshWindowPoll : nil, call.abandoned)
        }
        let captured = try capture ?? read(d.windows.keyWindow(target))
        try checkPage(app, captured)
        let window = try d.windows.keyWindow(target)
        let shot: Result<Shot, HarnessError>
        do {
            if let picture = d.picture {
                shot = .success(try picture(target, window))
            } else {
                shot = .success(
                    try d.screenshot.capture(
                        window,
                        extras: d.windows.extraWindows(target: target, windowID: window.windowID)
                            .map {
                                ($0.id, $0.frame)
                            }))
            }
        } catch let error as HarnessError { shot = .failure(error) }
        switch shot {
        case .success(let s): app.shot = s
        case .failure: app.shot = nil
        }
        let disableDiff =
            call.arguments["disableDiff"] as? Bool == true
            || call.environment["TERM_LLM_COMPUTER_DIFF"] == "0"
        let text = app.revisions!.present(captured, disableDiff: disableDiff)
        let prefix = d.instructions.prefix(agent: call.agent, bundleID: target.bundleID) ?? ""
        d.person.afterStateRead(target)
        app.active = true
        d.presence.halo(window)
        d.presence.liveView(window)
        d.presence.pointerActivity("loading")
        return (prefix + text, shot)
    }
    private func act(
        _ call: ToolCallRequest, targets: [Target] = [],
        takes: (AppTarget) throws -> Double = { _ in 0 },
        send: (AppSession, [Actions.Target]) throws -> Void
    ) throws -> ToolOutcome {
        try withSession(call, stateRead: false) { app, resolved in
            if !app.active { throw Errors.make("not_active", ["app": resolved.path]) }
            let running: AppTarget
            do { running = try d.apps.running(app.target) } catch {
                app.active = false
                throw error
            }
            if running != app.target {
                app.active = false
                throw Errors.make("not_active", ["app": resolved.path])
            }
            let target = app.target
            let planned = try takes(target)
            try stillWanted(call, planned: planned)
            let kind = d.apps.kind(target)
            let read = reader(target, kind)
            let unchecked = try app.pageUnchecked && d.policy.watchesURLs()
            var settled: Capture?
            if app.needsSettle && (unchecked || Self.settleBeforeKeys.contains(call.name)) {
                app.needsSettle = false
                settled = try d.settle(target, kind, read, nil, call.abandoned)
            }
            if unchecked { try checkPage(app, settled ?? read(d.windows.keyWindow(target))) }
            var whereTo: [Actions.Target] = []
            for item in targets {
                switch item {
                case .index(let index):
                    guard let revisions = app.revisions else {
                        throw Errors.make("no_invalidation_monitor")
                    }
                    whereTo.append(
                        .line(
                            try d.resolveElement(
                                revisions, index, { try read(self.d.windows.keyWindow(target)) },
                                Self.refetchIgnoresValue.contains(call.name))))
                case .point(let point):
                    guard let shot = app.shot else { throw Errors.make("screenshot_failed") }
                    whereTo.append(.point(shot.toScreen(x: point.x, y: point.y)))
                }
            }
            try stillWanted(call, planned: planned)  // settle/refetch took their time
            d.presence.pointerActivity("idle")
            // Even an action failing after its events changed the app needs a settle.
            app.needsSettle = true
            app.pageUnchecked = kind.http || kind.chromium
            if let action = d.send {
                try action(call, app, whereTo)
            } else {
                try send(app, whereTo)
            }
            d.presence.pointerActivity("loading")
            return try result(call, Self.actionLine, NSNull())
        }
    }
    private func result(_ call: ToolCallRequest, _ text: String, _ value: Any) throws -> ToolOutcome
    {
        guard call.arguments["json"] as? Bool == true else { return .text(text, json: false) }
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed, .withoutEscapingSlashes, .sortedKeys])
        return ToolOutcome(stdout: String(decoding: data, as: UTF8.self) + "\n")
    }
    public func execute(_ call: ToolCallRequest) throws -> ToolOutcome {
        let a = call.arguments
        func string(_ key: String, _ fallback: String = "") -> String {
            a[key] as? String ?? fallback
        }
        func line(_ targets: [Actions.Target]) throws -> Line {
            guard case .line(let line)? = targets.first else { throw Errors.make("stale_element") }
            return line
        }
        switch call.name {
        case "help":
            let text = try ToolParser.help(a["tool"] as? String)
            return try result(call, text, text)
        case "skill": return try result(call, ComputerUseSkill.text, ComputerUseSkill.text)
        case "doctor":
            let report = d.permissions.diagnostics()
            let data = try JSONSerialization.data(
                withJSONObject: report,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            return try result(call, String(decoding: data, as: UTF8.self), report)
        case "turn-started":
            call.sessions.turnStarted(call.agent)
            d.approvals.beginTurn(agent: call.agent)
            return try result(call, "", NSNull())
        case "turn-ended":
            let cancel = a["cancel"] as? Bool == true
            call.sessions.letGo(call.agent, cancel: cancel)
            try letGo(call.agent, cancelApprovals: cancel, withAppQueue: call.withCleanupQueue)
            return try result(call, "", NSNull())
        case "list_apps":
            let rows: [[String: Any]]
            do {
                rows = try d.listApps?(call.agent.hosts) ?? d.apps.listApps(hosts: call.agent.hosts)
            } catch let error as HarnessError {
                var failure = error
                failure.message = "Native apps: " + error.message
                throw failure
            }
            let data = try JSONSerialization.data(
                withJSONObject: rows, options: [.withoutEscapingSlashes, .sortedKeys])
            return try result(
                call, a["emit"] as? Bool == false ? "" : String(decoding: data, as: UTF8.self), rows
            )
        case "get_app_state":
            return try withSession(call, stateRead: true) { app, target in
                let (text, picture) = try readState(call, app, target)
                let screenshotLine: String
                let value: Any
                switch picture {
                case .success(var shot):
                    if a["keep"] as? Bool == true {
                        shot.path = try d.screenshot.keep(shot.path, appName: target.name)
                    }
                    screenshotLine = "Screenshot (\(shot.width)x\(shot.height) px): \(shot.path)"
                    value = ["url": URL(fileURLWithPath: shot.path).absoluteString]
                case .failure(let error):
                    screenshotLine = "Screenshot: none. \(error.message)"
                    value = NSNull()
                }
                let shown =
                    a["emit"] as? Bool == false
                    ? ""
                    : text.replacingOccurrences(of: "\n+$", with: "", options: .regularExpression)
                        + "\n\n"
                return try result(
                    call, shown + screenshotLine,
                    ["app": string("app"), "screenshot": value, "text": text])
            }
        case "click":
            let target = try target(a)
            let button = try Self.button(a["mouse_button"] ?? "left")
            let count = Self.integer(a["click_count"] ?? 1) ?? 0
            if count > Self.maxClicks {
                throw Usage.error("click_count", ["most": String(Self.maxClicks)])
            }
            let hold = try Self.hold(a)
            let key = a["key"] as? String
            if Double(count) * (hold ?? 0) > Self.maxHold { throw Usage.error("duration") }
            return try act(call, targets: [target], takes: { _ in Double(count) * (hold ?? 0) }) {
                try d.actions.click($0, $1[0], button: button, count: count, key: key, hold: hold)
            }
        case "drag":
            let start = try point(a, "from_x", "from_y", "from")
            let end = try point(a, "to_x", "to_y", "to")
            return try act(call, targets: [.point(start), .point(end)]) { app, targets in
                if case .point(let s) = targets[0], case .point(let e) = targets[1] {
                    try d.actions.drag(app, start: s, end: e)
                }
            }
        case "press_key":
            let key = string("key")
            if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw Usage.error("key")
            }
            let hold = try Self.hold(a)
            return try act(call, takes: { _ in hold ?? 0 }) { app, _ in
                try d.actions.pressKey(app, key, hold: hold)
            }
        case "type_text":
            let text = string("text")
            let count = text.unicodeScalars.count
            if count > Self.maxText {
                throw Usage.error("text_length", ["most": String(Self.maxText)])
            }
            return try act(
                call,
                takes: { target in
                    let each = 2 * (Limits.slowTyping[target.bundleID] ?? Limits.typeDelay)
                    if Double(count) * each > Self.maxHold {
                        throw Usage.error("text_length", ["most": String(Int(Self.maxHold / each))])
                    }
                    return Double(count) * each
                }
            ) { app, _ in try d.actions.typeText(app, text) }
        case "set_value":
            let index = try index(a)
            guard let value = a["value"] as? String else { throw Errors.make("no_value_to_set") }
            return try act(call, targets: [.index(index)]) {
                try d.actions.setValue($0, line($1), value)
            }
        case "scroll":
            guard let pages = Self.number(a["pages"] ?? 1), pages > 0 else {
                throw Usage.error("pages")
            }
            let target = try target(a)
            guard
                let direction = Self.directions[
                    string("direction").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                ]
            else { throw Usage.error("direction") }
            return try act(call, targets: [target]) {
                try d.actions.scroll($0, $1[0], direction: direction, pages: pages)
            }
        case "select_text":
            let index = try index(a)
            let mode = string("selection_type", "text")
            if Actions.selection[mode] == nil {
                throw Usage.error("selection_type", ["value": mode])
            }
            return try act(call, targets: [.index(index)]) {
                try d.actions.selectText(
                    $0, line($1), string("text"), prefix: string("prefix"),
                    suffix: string("suffix"),
                    mode: mode)
            }
        case "perform_secondary_action":
            let index = try index(a)
            return try act(call, targets: [.index(index)]) {
                try d.actions.secondary($0, line($1), string("action"))
            }
        case "paste":
            guard let text = a["text"] as? String else { throw Errors.make("no_text_to_paste") }
            let format = string("format", "text").trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return try act(call) { app, _ in try d.actions.paste(app, text, format: format) }
        default: throw Errors.serverError("Unknown tool '\(call.name)'.")
        }
    }
    /// Turn end and dead-agent reaping share this path. Cleanup uses the same app
    /// FIFO but cannot be abandoned by the already-ended turn/dead client.
    public func letGo(
        _ agent: AgentSession, cancelApprovals: Bool = false,
        withAppQueue: (String, () throws -> ToolOutcome) throws -> ToolOutcome
    ) throws {
        if cancelApprovals || agent.ended || agent.exited { d.approvals.cancel(keys: [agent.key]) }
        d.person.turnEnded(agent)
        for app in appSessions(agent) {
            _ = try withAppQueue(app.target.path) {
                switchOff(app)
                let path = app.target.path
                // Another cleanup may have retired this snapshot before our FIFO turn.
                let retired: AppSession? = state.withLock { state in
                    guard state.apps[agent.key]?[path] === app else { return nil }
                    let removed = state.apps[agent.key]?.removeValue(forKey: path)
                    state.appOrder[agent.key]?.removeAll { $0 == path }
                    return removed
                }
                // The appSessions snapshot retains all apps through the loop.
                // Keep this reference outside the registry lock too; final deinit
                // and observer stop may run after the loop, outside the app FIFO.
                withExtendedLifetime(retired) {}
                return ToolOutcome()
            }
        }
        state.withLock { state in
            if state.apps[agent.key]?.isEmpty == true {
                state.apps.removeValue(forKey: agent.key)
                state.appOrder.removeValue(forKey: agent.key)
            }
        }
        if d.person.driven().isEmpty { d.presence.turnDone() }
        d.approvals.clearDenials(agent: agent)
    }
    public func cancel(agentKeys: Set<String>) {
        d.approvals.cancel(keys: agentKeys)
    }
    public func agentExited(
        _ agent: AgentSession,
        withAppQueue: (String, () throws -> ToolOutcome) throws -> ToolOutcome
    ) {
        try? letGo(agent, cancelApprovals: true, withAppQueue: withAppQueue)
    }
    public func shutdown() {
        let retired = state.withLock { state in
            let retired = state.apps
            state.apps = [:]
            state.appOrder = [:]
            return retired
        }
        for app in retired.values.flatMap({ $0.values }) { switchOff(app) }
        d.focus.releaseAll()
        Tree.disableAll()
        d.actions.system.pasteboard.restoreSaved()
        d.presence.turnDone()
        d.screenshot.cleanup()
        ActivityBanner.shared.stop()
    }
}
