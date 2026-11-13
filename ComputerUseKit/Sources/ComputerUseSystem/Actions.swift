import ComputerUseCore
import CoreGraphics
import Foundation
import os

/// How each tool reaches the app. Top rung first: AX action/attribute, events to
/// the window's pid, then keys after a made-up activation. No rung moves the real
/// pointer or brings the app forward. Only an explicitly requested Raise changes
/// window order. Nothing here waits for the app afterwards or reads state.
public final class Actions: Sendable {
    // A hidden centre lands on the centre of the part that shows. Off also refuses
    // elements that are mostly in view.
    public static let clickVisiblePart = true
    // Escape uses the menu's Cancel action; otherwise a posted key leaves its view.
    public static let escapeCancelsMenu = true
    // Pressing a background menu title draws on the person's menu bar and takes
    // their next clicks/keys. Instead read its menu and pick items by AX action.
    public static let pressMenuTitles = false
    public static let alwaysSimulateClick = "TERM_LLM_COMPUTER_ALWAYS_SIMULATE_CLICK"
    public static let moveLead = 0.067, scrollLead = 0.017, scrollRest = 0.010, clickGap = 0.1
    // Measured: AppKit drops with 26-point/20ms steps; 0 of 6 with >=65 points.
    public static let dragSpan = 20.0, dragStep = 0.02, dragMax = 60
    public static let longWait = 0.1, pressJoin = 0.25, fillWait = 0.25, fillPoll = 0.01
    public static let minExtent = 100.0, maxParents = 300
    public static let escape = Keys.Chord(53, 0)
    public static let menuFailed = Errors.make("menu_click_failed").message
    public static let browserField = "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD"
    public static let nameField = "saveAsNameTextField"
    public static let wheel = ["up": (0, 1), "down": (0, -1), "left": (-1, 0), "right": (1, 0)]
    public static let menuRoles: Set<String> = ["AXMenuBarItem", "AXMenuItem"]
    public static let opensMenu: Set<String> = ["AXMenuBarItem", "AXPopUpButton", "AXMenuButton"]
    public static let maySelect: Set<String> = ["AXRow", "AXCell"]  // never Command tier
    // Web buttons/links/fields/sliders/summary need real clicks (which focus them).
    public static let webActionRoles: Set<String> = ["AXCheckBox", "AXRadioButton"]
    public static let textFields: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
    ]
    public static let selection = ["text": (0, 1), "cursor_before": (0, 0), "cursor_after": (1, 1)]
    public static let disclose = ["Expand": true, "Collapse": false]
    public static let pageButton = [
        "Scroll Up": ("AXVerticalScrollBar", "AXDecrementPage"),
        "Scroll Down": ("AXVerticalScrollBar", "AXIncrementPage"),
        "Scroll Left": ("AXHorizontalScrollBar", "AXDecrementPage"),
        "Scroll Right": ("AXHorizontalScrollBar", "AXIncrementPage"),
    ]

    public enum Target: Sendable {
        case line(Line)
        case point(CGPoint)
    }
    /// All event posting, app/window resolution and clocks can be replaced without
    /// granting permissions, displaying windows or touching a live application.
    /// Configure a value copy before construction. An Actions instance retains an
    /// immutable snapshot; callbacks may be called concurrently by app workers.
    /// CGEvent and heterogeneous AX values remain synchronous operation-local
    /// arguments/results, never payloads for `background` or other workers.
    public struct System: Sendable {
        public var apps = Apps.shared
        public var windows = Windows.shared
        public var focus = Focus.shared
        public var presence = Presence.shared
        public var pasteboard = Pasteboard()
        public var checkRecipient: @Sendable (String) throws -> Void = { try Policy().checkRecipient($0) }
        public var post: @Sendable (pid_t, CGEvent, TimeInterval) -> Void = {
            Events.post($0, event: $1, delay: $2)
        }
        public var heldFlags: @Sendable () -> UInt64 = { Events.heldFlags() }
        public var presses: @Sendable (String) throws -> [Keys.KeyPress] = { try Keys.presses($0) }
        public var printedText: @Sendable (UIElementRef) throws -> (String, [Int]?) = { try Tree.printedText($0) }
        public var focusElement: @Sendable (UIElementRef) -> Bool = { Focus.focusElement($0) }
        public var now: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        public var sleep: @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
        public var background: @Sendable (@escaping @Sendable () -> Void) -> Void = {
            DispatchQueue.global().async(execute: $0)
        }
        public init() {}
    }
    public let system: System
    public init(system: System = .init()) { self.system = system }
    private var ax: AXBackend { AX.backend }
    private func get(_ e: UIElementRef, _ name: String) -> Any? { try? ax.get(e, name) }
    private func children(_ e: UIElementRef) -> [UIElementRef] {
        get(e, "AXChildren") as? [UIElementRef] ?? []
    }
    public static func centre(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
    public static func cut(_ a: CGRect?, _ b: CGRect?) -> CGRect? {
        guard let a, let b else { return a }
        let r = a.intersection(b)
        return r.isNull || r.width <= 0 || r.height <= 0 ? nil : r
    }
    public static func inside(_ p: CGPoint, _ r: CGRect) -> Bool {
        p.x >= r.minX && p.x < r.maxX && p.y >= r.minY && p.y < r.maxY
    }
    public static func pages(_ n: Double, extent: Double) -> Int {
        Int(floor(n * max(extent, minExtent) + 0.5))
    }
    public func chain(_ element: UIElementRef?) throws -> [(UIElementRef, String)] {
        var current = element
        var out: [(UIElementRef, String)] = []
        while let e = current, out.count <= Self.maxParents {
            let role = try ax.get(e, "AXRole") as? String ?? ""
            out.append((e, role))
            current = role == "AXWindow" ? nil : try ax.get(e, "AXParent") as? UIElementRef
        }
        return out
    }
    public func visiblePart(_ e: UIElementRef, _ w: ComputerUseCore.WindowRef) throws -> CGRect? {
        let f = ax.frame(e)
        var part = f.flatMap { $0.width > 0 && $0.height > 0 ? Self.cut($0, w.frame) : nil }
        for (p, r) in try chain(e).dropFirst() where r == "AXScrollArea" {
            part = Self.cut(part, ax.frame(p))
        }
        return part
    }
    @discardableResult public func position(_ e: UIElementRef, _ w: ComputerUseCore.WindowRef)
        throws
        -> Bool
    {
        for ask in [false, true] {
            if ask {
                do {
                    if ax.actionNames(e).contains("AXScrollToVisible") {
                        try ax.perform(e, "AXScrollToVisible")
                    }
                    for (p, r) in try chain(e).dropFirst() where r == "AXScrollArea" {
                        _ = ax.param(p, "AXScrollToShowDescendant", e)
                        break
                    }
                } catch is HarnessError {}  // a refused hint still permits visible-part fallback
            }
            if let part = try visiblePart(e, w), let frame = ax.frame(e),
                Self.inside(Self.centre(frame), part)
            {
                return true
            }
        }
        return false
    }
    public func clickablePoint(_ e: UIElementRef, _ w: ComputerUseCore.WindowRef) throws -> CGPoint
    {
        if try position(e, w), let f = ax.frame(e) { return Self.centre(f) }
        guard Self.clickVisiblePart, let part = try visiblePart(e, w) else {
            throw Errors.make("cannot_click_offscreen")
        }
        return Self.centre(part)
    }
    private func scrollTo(_ e: UIElementRef, _ part: CGRect) throws {
        guard let holder = try chain(e).dropFirst().first(where: { $0.1 == "AXScrollArea" })?.0,
            let area = ax.frame(holder), let content = ax.frame(e)
        else { return }
        for (horizontal, name) in [(true, "AXHorizontalScrollBar"), (false, "AXVerticalScrollBar")]
        {
            let low = horizontal ? part.minX : part.minY
            let size = horizontal ? part.width : part.height
            let origin = horizontal ? area.minX : area.minY
            let extent = horizontal ? area.width : area.height
            let room = (horizontal ? content.width : content.height) - extent
            if origin <= low && low + size <= origin + extent || room <= 0 { continue }
            if let bar = get(holder, name) as? UIElementRef {
                let off = low + size / 2 - (origin + extent / 2)
                let share = (get(bar, "AXValue") as? NSNumber)?.doubleValue ?? 0
                try? ax.set(bar, "AXValue", min(1, max(0, share + off / room)))
            }
        }
    }
    private func at(_ app: AppSession, _ p: CGPoint) throws -> (
        ComputerUseCore.WindowRef, UIElementRef?
    ) {
        var w = try system.windows.at(app.target, point: p)
        let e = ax.at(ax.app(pid: app.target.pid!), x: p.x, y: p.y)
        if let e, try ax.pid(e) != app.target.pid { w = try system.windows.ref(e) }
        return (w, e)
    }
    @discardableResult private func recipient(_ app: AppSession, _ pid: pid_t) throws -> pid_t {
        // A password sheet drawn by another process is not covered by app approval.
        if pid != app.target.pid { try system.checkRecipient(system.apps.bundleID(pid)) }
        return pid
    }
    private func owner(_ app: AppSession, _ e: UIElementRef) throws {
        if let pid = try? ax.pid(e) { try recipient(app, pid) }
    }
    private func frontWindow(_ app: AppSession) -> ComputerUseCore.WindowRef? {
        try? system.windows.keyWindow(app.target)
    }
    private func keyPID(_ app: AppSession, activated: Bool) throws -> pid_t {
        let root = ax.app(pid: app.target.pid!)
        let focused = get(root, "AXFocusedUIElement") as? UIElementRef
        let w = get(root, "AXFocusedWindow") as? UIElementRef
        let panel =
            w.map { Apps.filePanels.contains(get($0, "AXIdentifier") as? String ?? "") } ?? false
        // Open/save service takes keys only at its own pid. After fake activation
        // its focused field needs a click to get those keys back (TextEdit measured).
        if panel, let service = system.apps.panelService(app.target.pid!) {
            if activated, let focused { try clickOnce(app, focused) }
            return try recipient(app, service)
        }
        return try focused.map { try recipient(app, ax.pid($0)) } ?? app.target.pid!
    }
    private func needsActivation(_ app: AppSession, _ e: UIElementRef?, forced: Bool) throws -> Bool
    {
        let k = system.apps.kind(app.target)
        let roles = try chain(e).map { $0.1 }
        return forced || k.chromium || k.electron || roles.contains("AXWebArea")
            || !Self.maySelect.isDisjoint(with: roles)
            || (k.catalyst && roles.first == "AXMenuButton")
    }
    public func pause(_ seconds: Double, cancel: () -> Bool) {
        let deadline = system.now() + seconds
        while deadline - system.now() > 0 {
            if seconds > Self.longWait && cancel() { return }
            system.sleep(min(deadline - system.now(), Self.longWait / 2))
        }
    }
    private func goOn(_ app: AppSession) throws {
        if app.cancel() { throw Errors.make("user_changed", ["app_path": app.target.path]) }
    }
    @discardableResult private func show(_ e: UIElementRef, _ w: ComputerUseCore.WindowRef? = nil)
        -> ComputerUseCore.WindowRef?
    {
        let window = w ?? (try? system.windows.ref(e))
        if let f = ax.frame(e) { system.presence.flash(f, window: window) }
        return window
    }
    private func usable(_ w: ComputerUseCore.WindowRef) throws {
        if w.windowID == 0 { throw Errors.make("no_window_id") }
        if get(w.element, "AXMinimized") as? Bool == true {
            throw Errors.make("cannot_click_offscreen")
        }
    }
    private func aim(_ e: UIElementRef) throws -> (ComputerUseCore.WindowRef, CGPoint) {
        if let own = get(e, "AXWindow") as? UIElementRef, get(own, "AXMinimized") as? Bool == true {
            throw Errors.make("cannot_click_offscreen")
        }
        let w = try system.windows.ref(e)
        return (w, try clickablePoint(e, w))
    }
    private func unanswered(_ error: HarnessError) -> Bool {
        error.message.contains("cannotComplete")
    }
    private typealias MouseStep = (kind: String, point: CGPoint, count: Int, wait: Double)
    private func deliver(
        _ app: AppSession, _ w: ComputerUseCore.WindowRef, _ e: UIElementRef?,
        _ series: [MouseStep],
        button: Int = 0, key: String? = nil, hold: Double? = nil, lead: Double? = nil
    ) throws {
        try usable(w)
        let enforcer = system.focus.enforcer(app.target)
        let pid = try recipient(app, w.pid)
        let held = UInt64(try key.map { try Keys.modifiers($0) } ?? 0)
        let before = system.heldFlags()
        var flags = held
        var pressed: (CGPoint, Int)?
        Focus.inputLock.lock()
        defer { Focus.inputLock.unlock() }
        if let lead, let first = series.first {
            system.post(pid, Events.mouse("moved", point: first.point, window: w), lead)
        }
        let activate =
            try !enforcer.believesFocus
            && needsActivation(app, e, forced: key != nil || hold != nil)
        if !enforcer.believesFocus && !activate { flags |= UInt64(Keys.command) }
        let send = {
            if held != 0 { self.system.post(pid, Events.flagsChanged(held), 0) }
            // A down always gets its up, even if the person takes over mid-hold.
            defer {
                if let p = pressed {
                    self.system.post(
                        pid,
                        Events.mouse(
                            "up", point: p.0, window: w, button: button, click: p.1, flags: flags),
                        0)
                }
                if held != 0 { self.system.post(pid, Events.flagsChanged(before), 0) }
            }
            for step in series {
                try self.goOn(app)
                self.system.post(
                    pid,
                    Events.mouse(
                        step.kind, point: step.point, window: w, button: button, click: step.count,
                        flags: flags
                    ), 0)
                pressed =
                    step.kind == "up"
                    ? nil : (step.point, step.count != 0 ? step.count : (pressed?.1 ?? 1))
                self.pause(
                    step.kind == "down" ? (hold ?? step.wait) : step.wait, cancel: app.cancel)
            }
        }
        if activate { try enforcer.active(window: w, send) } else { try send() }
    }
    private func clickOnce(_ app: AppSession, _ e: UIElementRef) throws {
        let (w, p) = try aim(e)
        try deliver(app, w, e, [("down", p, 1, Events.clickHold), ("up", p, 1, 0)])
    }
    /// AXPress may block until a menu closes. Perform it on the side while waiting
    /// for the menu; never retry a timed-out action, which may still have happened.
    private func press(_ app: AppSession, _ e: UIElementRef, _ action: String, role: String = "")
        throws
    {
        if !(Self.opensMenu.contains(role) && ["AXPress", "AXPick"].contains(action))
            && action != "AXShowMenu"
        {
            try ax.perform(e, action)
            return
        }
        let result = PendingPress()
        let backend = self.ax // Task-local backend scopes do not follow GCD work.
        system.background { result.run { try backend.perform(e, action) } }
        if try system.windows.waitForMenu(app.target, opener: e) != nil { return }
        result.wait(Self.pressJoin)
        // Sample completion and failure together: a late failure must not turn
        // into a successful press between separate error/finished reads.
        let outcome = result.outcome
        if let outcome { try outcome.get() }
        let menus = children(e).filter { get($0, "AXRole") as? String == "AXMenu" }
        if outcome == nil || !menus.isEmpty {
            for menu in menus { try? ax.perform(menu, "AXCancel") }
            throw Errors.make("menu_click_failed")
        }
    }
    public func cancelMenu(_ app: AppSession) throws {
        defer { system.windows.closeMenu(app.target) }
        if let menu = try system.windows.shownMenu(app.target) { try? ax.perform(menu, "AXCancel") }
    }
    private func hasItems(_ title: UIElementRef) -> Bool {
        children(title).contains { !children($0).isEmpty }
    }
    private func fill(_ title: UIElementRef) {
        // The real menu owns the person's input while open: keep this interval tiny.
        let result = PendingPress()
        let backend = self.ax // Capture before leaving the caller's dependency scope.
        system.background { result.run { try backend.perform(title, "AXPress") } }
        let deadline = system.now() + Self.fillWait
        while !hasItems(title) && system.now() < deadline { system.sleep(Self.fillPoll) }
        for menu in children(title) { try? ax.perform(menu, "AXCancel") }
        result.wait(Self.pressJoin)
    }
    private func pressAction(_ e: UIElementRef) -> String? {
        let offered = ax.actionNames(e)
        return ["AXPick", "AXPress"].first { offered.contains($0) }
    }
    private func menuClick(_ app: AppSession, _ line: Line) throws {
        guard let element = line.element else { throw Errors.make("stale_element") }
        do {
            if line.role == "AXMenuBarItem" {
                try system.focus.enforcer(app.target).active(window: frontWindow(app)) {
                    if !Self.pressMenuTitles {
                        if !hasItems(element) { fill(element) }
                        if !hasItems(element) {
                            throw Errors.make("menu_fills_on_open", ["title": line.name])
                        }
                        system.windows.keepMenu(app.target, title: element)
                    } else {
                        try press(app, element, "AXPress", role: line.role)
                    }
                }
                return
            }
            try ax.perform(element, pressAction(element) ?? "AXPress")
        } catch let error as HarnessError {
            if unanswered(error)
                || error.message == Errors.make("menu_fills_on_open", ["title": line.name]).message
            {
                system.windows.closeMenu(app.target)
                throw error
            }
            try cancelMenu(app)
            throw Errors.make("menu_click_failed")
        }
        system.windows.closeMenu(app.target)
    }
    public func click(
        _ app: AppSession, _ target: Target, button: Int = 0, count: Int = 1, key: String? = nil,
        hold: Double? = nil
    ) throws {
        if count < 1 { throw Errors.make("invalid_click_count") }
        let plain = button == 0 && count == 1 && key == nil && hold == nil
        let w: ComputerUseCore.WindowRef
        let p: CGPoint
        let e: UIElementRef?
        let lead: Double?
        switch target {
        case .line(let line):
            guard let element = line.element else { throw Errors.make("stale_element") }
            try owner(app, element)
            if Self.menuRoles.contains(line.role) {
                if !plain { throw Errors.make("menu_action_not_supported") }
                try menuClick(app, line)
                return
            }
            var action = pressAction(element)
            if try !Self.webActionRoles.contains(line.role)
                && chain(element).contains(where: { $0.1 == "AXWebArea" })
            {
                action = nil
            }
            if plain, let action, app.agent.env[Self.alwaysSimulateClick] != "1" {
                let window = try? system.windows.ref(element)
                if let window { _ = try? position(element, window) }
                show(element, window)
                system.presence.pointerPress(count: 1)
                do {
                    try press(app, element, action, role: line.role)
                    return
                } catch let error as HarnessError {
                    if unanswered(error)
                        || error.message == Errors.make("menu_click_failed").message
                    {
                        throw error
                    }
                }
                // Refused AX action: fall through to events, not a second AX press.
            }
            (w, p) = try aim(element)
            e = element
            lead = nil
            show(element, w)
        case .point(let point):
            p = point
            lead = Self.moveLead
            (w, e) = try at(app, point)
        }
        system.presence.pointerMove(p, window: w)
        system.presence.pointerPress(count: count)
        var series: [MouseStep] = []
        for i in 1...count {
            series += [
                ("down", p, i, Events.clickHold), ("up", p, i, i == count ? 0 : Self.clickGap),
            ]
        }
        try deliver(app, w, e, series, button: button, key: key, hold: hold, lead: lead)
    }
    public func drag(_ app: AppSession, start: CGPoint, end: CGPoint) throws {
        // One midpoint drops 0/4 in AppKit; the short-step path drops 7/7.
        let (w, e) = try at(app, start)
        let span = hypot(end.x - start.x, end.y - start.y)
        let steps = Int(min(Double(Self.dragMax), max(2, ceil(span / Self.dragSpan))))
        let points = (0...steps).map {
            CGPoint(
                x: start.x + (end.x - start.x) * Double($0) / Double(steps),
                y: start.y + (end.y - start.y) * Double($0) / Double(steps))
        }
        system.presence.pointerMove(start, window: w)
        system.presence.pointerPress(count: 1)
        let path: [MouseStep] = points.map { ("dragged", $0, 0, Self.dragStep) }
        try deliver(
            app, w, e, [("down", start, 1, Self.dragStep)] + path + [("up", end, 1, 0)],
            lead: Self.moveLead)
        system.presence.pointerMove(end, window: w)
    }
    public func scroll(_ app: AppSession, _ target: Target, direction: String, pages: Double) throws
    {
        let w: ComputerUseCore.WindowRef
        let p: CGPoint
        let frame: CGRect
        switch target {
        case .line(let line):
            guard let element = line.element else { throw Errors.make("stale_element") }
            (w, p) = try aim(element)
            frame = ax.frame(element) ?? w.frame
            show(element, w)
        case .point(let point):
            p = point
            (w, _) = try at(app, point)
            frame = w.frame
        }
        try usable(w)
        try recipient(app, w.pid)
        guard let (x, y) = Self.wheel[direction] else { throw Usage.error("direction") }
        let extent = x != 0 ? frame.width : frame.height
        guard (pages * max(extent, Self.minExtent)).isFinite,
            pages * max(extent, Self.minExtent) < Double(Int32.max)
        else { throw Usage.error("pages") }
        let n = Self.pages(pages, extent: extent)
        system.presence.pointerMove(p, window: w)
        Focus.inputLock.lock()
        defer { Focus.inputLock.unlock() }
        system.post(w.pid, Events.mouse("moved", point: p, window: w), Self.scrollLead)
        system.post(w.pid, Events.wheel(p, dx: x * n, dy: y * n, window: w), Self.scrollRest)
    }
    public func sendKeys(
        _ app: AppSession, _ presses: [Keys.KeyPress], delay: Double = 0, hold: Double? = nil
    ) throws {
        let enforcer = system.focus.enforcer(app.target)
        let w = enforcer.believesFocus ? nil : frontWindow(app)
        try enforcer.active(window: w) {
            let pid = try keyPID(app, activated: w != nil)
            for (i, press) in presses.enumerated() {
                try goOn(app)
                let before = system.heldFlags()
                let flags = UInt64(press.flags)
                let text = press.text.isEmpty ? nil : press.text
                let changed = before & Events.modifiers != flags
                if changed { system.post(pid, Events.flagsChanged(flags), delay) }
                system.post(pid, Events.key(press.code, flags: flags, text: text), delay)
                defer {
                    system.post(
                        pid, Events.key(press.code, flags: flags, text: text, down: false), delay)
                    if changed { system.post(pid, Events.flagsChanged(before), delay) }
                }
                if let hold, i == presses.count - 1 { pause(hold, cancel: app.cancel) }
            }
        }
    }
    public func pressKey(_ app: AppSession, _ spec: String, hold: Double? = nil) throws {
        let chords = try Keys.chords(spec)
        if Self.escapeCancelsMenu && chords == [Self.escape],
            try system.windows.shownMenu(app.target) != nil
        {
            try cancelMenu(app)
            return
        }
        try sendKeys(app, chords.map { Keys.KeyPress($0.code, $0.flags, "") }, hold: hold)
    }
    private func noPathAsName(_ e: UIElementRef?, _ text: String) throws {
        if let e, get(e, "AXIdentifier") as? String == Self.nameField, text.contains("/") {
            throw Errors.make("path_in_file_name")
        }
    }
    public func typeText(_ app: AppSession, _ text: String) throws {
        if text.isEmpty { throw Errors.make("no_text_to_type") }
        try noPathAsName(
            get(ax.app(pid: app.target.pid!), "AXFocusedUIElement") as? UIElementRef, text)
        try sendKeys(
            app, system.presses(text),
            delay: Limits.slowTyping[app.target.bundleID] ?? Limits.typeDelay)
    }
    public func paste(_ app: AppSession, _ text: String, format: String) throws {
        let field = get(ax.app(pid: app.target.pid!), "AXFocusedUIElement") as? UIElementRef
        let watched = ["AXValue", "AXSelectedTextRange", "AXNumberOfCharacters"]
        let before = try field.map { try ax.getMany($0, watched) } ?? []
        let any = before.contains { value in
            guard let v = value else { return false }
            if let n = v as? NSNumber { return n.doubleValue != 0 }
            if let s = v as? String { return !s.isEmpty }
            return true
        }
        let landed: (() -> Bool)? =
            any
            ? {
                guard let field, let after = try? self.ax.getMany(field, watched) else {
                    return false
                }
                return !NSArray(array: before.map { $0 ?? NSNull() }).isEqual(
                    to: after.map { $0 ?? NSNull() })
            } : nil
        try system.pasteboard.paste(
            text, format: format, sendPasteKey: { try self.pressKey(app, "super+v") },
            landed: landed)
    }
    public static func like(_ current: Any?, _ value: String) -> Any {
        if let n = current as? NSNumber, let number = Double(value) {
            if String(cString: n.objCType) != "d" && String(cString: n.objCType) != "f"
                && number.isFinite
                && number.rounded() == number && number >= Double(Int.min)
                && number < Double(Int.max)
            {
                return Int(number)
            }
            return number
        }
        return value
    }
    public func setValue(_ app: AppSession, _ line: Line, _ value: String) throws {
        guard let e = line.element else { throw Errors.make("stale_element") }
        try owner(app, e)
        if !ax.settable(e, "AXValue") { throw Errors.make("not_settable") }
        try noPathAsName(e, value)
        show(e)
        // A background TextEdit document saved right after an unclicked write waits
        // on itself for good. A text area is clicked even if it already has focus.
        let document = line.role == "AXTextArea"
        let unfocused = Self.textFields.contains(line.role) && get(e, "AXFocused") as? Bool != true
        if document || (unfocused && !system.focusElement(e)) { try clickOnce(app, e) }
        try ax.set(e, "AXValue", Self.like(try ax.get(e, "AXValue"), value))
        let values = try ax.getMany(e, ["AXIdentifier", "AXKeyShortcutsValue"])
        // Only browser address fields submit. App search fields await a Return call.
        if values[0] as? String == Self.browserField || values[1] as? String == "⌘L" {
            try pressKey(app, "Return")
        }
    }
    public func selectText(
        _ app: AppSession, _ line: Line, _ text: String, prefix: String = "", suffix: String = "",
        mode: String = "text"
    ) throws {
        guard let indices = Self.selection[mode] else {
            throw Usage.error("selection_type", ["value": mode])
        }
        guard let e = line.element else { throw Errors.make("stale_element") }
        try owner(app, e)
        let plain = ax.settable(e, "AXSelectedTextRange")
        if !plain && !ax.settable(e, "AXSelectedTextMarkerRange") {
            throw Errors.make("cannot_select_text")
        }
        // Search the Markdown as printed; offsets map it back to app plain text.
        let (printed, offsets) = try system.printedText(e)
        guard let found = RichText.find(printed, offsets, text, prefix: prefix, suffix: suffix)
        else {
            throw Errors.make("text_not_found")
        }
        let ends = [found.0, found.1]
        let start = ends[indices.0]
        let end = ends[indices.1]
        let span = NSRange(location: start, length: end - start)
        if get(e, "AXFocused") as? Bool != true { _ = system.focusElement(e) }
        if let hidden = ax.param(e, "AXBoundsForRange", span) as? CGRect { try scrollTo(e, hidden) }
        if let shown = ax.param(e, "AXBoundsForRange", span) as? CGRect {
            system.presence.pointerMove(Self.centre(shown), window: try? system.windows.ref(e))
        }
        if plain {
            try ax.set(e, "AXSelectedTextRange", span)
            return
        }
        let marks = [start, end].compactMap { ax.param(e, "AXTextMarkerForIndex", $0) }
        guard marks.count == 2,
            let range = ax.param(e, "AXTextMarkerRangeForUnorderedTextMarkers", marks)
        else { throw Errors.make("cannot_select_text") }
        try ax.set(e, "AXSelectedTextMarkerRange", range)
    }
    private func pageButton(_ e: UIElementRef, _ bar: String, _ part: String) throws -> Bool {
        if let b = get(e, bar) as? UIElementRef {
            for child in children(b) where get(child, "AXSubrole") as? String == part {
                try ax.perform(child, "AXPress")
                return true
            }
        }
        return false
    }
    public func secondary(_ app: AppSession, _ line: Line, _ action: String) throws {
        guard let name = line.actions.first(where: { $0.label == action })?.action else {
            throw Errors.make(
                "invalid_secondary_action", ["action": action, "index": String(line.id ?? 0)])
        }
        guard let e = line.element else { throw Errors.make("stale_element") }
        try owner(app, e)
        show(e)
        let disclosing = ["AXDisclosing", "AXExpanded"].first { ax.settable(e, $0) }
        if let value = Self.disclose[action], let disclosing {
            try ax.set(e, disclosing, value)
        } else if let (bar, part) = Self.pageButton[action], try pageButton(e, bar, part) {
        } else if name == "AXPick" {
            try menuClick(app, line)
        } else if name == "AXCancel" {
            defer { system.windows.closeMenu(app.target) }
            try ax.perform(e, name)
        } else {
            try press(app, e, name, role: line.role)
        }
    }
}

/// State shared with the AX menu worker. A timeout never reads unsynchronized data.
private final class PendingPress: Sendable {
    // The condition coordinates notification/wait, while typed storage owns all
    // mutations. Acquire condition before state when both are needed. Work and
    // error construction run outside both locks, including after caller timeout.
    private let condition = NSCondition()
    private let state = OSAllocatedUnfairLock<Result<Void, Error>?>(initialState: nil)
    var outcome: Result<Void, Error>? { state.withLock { $0 } }
    func run(_ work: () throws -> Void) {
        let outcome = Result(catching: work)
        condition.lock()
        state.withLock { $0 = outcome }
        condition.broadcast()
        condition.unlock()
    }
    func wait(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        condition.lock()
        defer { condition.unlock() }
        while outcome == nil && Date() < deadline { _ = condition.wait(until: deadline) }
    }
}
