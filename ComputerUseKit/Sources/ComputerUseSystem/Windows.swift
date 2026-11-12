import AppKit
import ComputerUseCore
import os

/// Fresh window and menu context. Global points, top-left origin; never clamp to zero.
public final class Windows {
    public static let maxParents = 300, menuWait = 0.25, menuPoll = 0.01
    public static let menuOpened = "AXMenuOpened", menuClosed = "AXMenuClosed"
    public static let newWindows = ["AXWindowCreated", "AXSheetCreated"]
    public static let keyWindowAttributes = ["AXFocusedWindow", "AXMainWindow", "AXWindows"]
    public static let windowListAll: UInt32 = 0 // on screen or not
    public static let desktop = "AXDesktop", menuButtons = ["AXPopUpButton", "AXMenuButton"]
    public struct Row: Equatable {
        public var id: UInt32; public var pid: pid_t; public var title: String?; public var layer: Int; public var frame: CGRect
        public init(id: UInt32, pid: pid_t, title: String? = nil, layer: Int = 0, frame: CGRect) {
            self.id = id; self.pid = pid; self.title = title; self.layer = layer; self.frame = frame
        }
    }
    public struct System {
        public var rows: (UInt32, UInt32) -> [Row] = Windows.systemRows
        public var associated: (UInt32) -> Set<UInt32> = Windows.systemAssociated
        public var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        public var sleep: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)
        public var noAttention: @Sendable (pid_t) -> Void = { Focus.noAttention($0) }
        public init() {}
    }
    public var system: System
    public static let shared = Windows()
    public init(system: System = .init()) { self.system = system }
    public static func keyWindow(_ target: AppTarget) throws -> ComputerUseCore.WindowRef { try shared.keyWindow(target) }
    public static func systemRows(_ option: UInt32, _ id: UInt32) -> [Row] {
        let rows = CGWindowListCopyWindowInfo(CGWindowListOption(rawValue: option), id) as? [[String: Any]] ?? []
        return rows.map { row in
            let box = row[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            return Row(id: (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0,
                       pid: (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0,
                       title: row[kCGWindowName as String] as? String,
                       layer: (row[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                       frame: CGRect(x: box["X"] ?? 0, y: box["Y"] ?? 0, width: box["Width"] ?? 0, height: box["Height"] ?? 0))
        }
    }
    public static func systemAssociated(_ id: UInt32) -> Set<UInt32> { systemAssociated(id, symbol: Events.privateSymbol) }
    public static func systemAssociated(_ id: UInt32, symbol: (String) -> UnsafeMutableRawPointer?) -> Set<UInt32> {
        typealias Connection = @convention(c) () -> Int32
        typealias Copy = @convention(c) (Int32, UInt32) -> Unmanaged<CFArray>?
        guard let c = symbol("CGSMainConnectionID"), let f = symbol("CGSCopyAssociatedWindows") else { return [] }
        let connection = unsafeBitCast(c, to: Connection.self), copy = unsafeBitCast(f, to: Copy.self)
        let values = copy(connection(), id)?.takeRetainedValue() as? [NSNumber] ?? []
        return Set(values.map(\.uint32Value))
    }
    public func serverWindows(pid: pid_t? = nil) -> [Row] { system.rows(1 | 16, 0).filter { pid == nil || $0.pid == pid } }
    public func serverWindow(_ id: UInt32) -> Row? {
        // Asking for one leaves out a minimised window (measured). All windows has it.
        for option: UInt32 in [8, Self.windowListAll] { if let row = system.rows(option, option == 0 ? 0 : id).first(where: { $0.id == id }) { return row } }
        return nil
    }
    public func extraWindows(target: AppTarget, windowID: UInt32) -> [Row] {
        let rows = serverWindows(pid: target.pid)
        guard let index = rows.firstIndex(where: { $0.id == windowID }) else { return [] }
        // Back to front; a sheet that is key is pictured alone, without its parent.
        return rows[..<index].reversed().filter { system.associated($0.id).contains(windowID) }
    }
    func app(_ target: AppTarget) throws -> UIElementRef {
        guard let pid = target.pid else { throw Errors.make("app_not_running", ["identifier": target.path]) }
        return AX.backend.app(pid: pid)
    }
    func isDesktop(_ element: UIElementRef) throws -> Bool { try AX.backend.get(element, "AXSubrole") as? String == Self.desktop }
    public func windowRef(_ element: UIElementRef) throws -> ComputerUseCore.WindowRef {
        let pid = try AX.backend.pid(element), title = try AX.backend.get(element, "AXTitle") as? String, frame = AX.backend.frame(element)
        var id = AX.backend.windowID(element)
        if id == 0, let frame {
            let same = serverWindows(pid: pid).filter { $0.frame == frame }
            id = same.first(where: { $0.title == title })?.id ?? same.first?.id ?? 0
        }
        // Name it as the server does: "All Fonts", not "All Fonts - 385 typefaces".
        // TODO(integration): follow bounds live; currently refreshed each read/action.
        let named = id == 0 ? title : (serverWindow(id).map { $0.title } ?? title)
        return ComputerUseCore.WindowRef(element: element, windowID: id, pid: pid, title: named, frame: frame ?? .zero)
    }
    public func keyWindow(_ target: AppTarget) throws -> ComputerUseCore.WindowRef {
        let values = try AX.backend.getMany(app(target), Self.keyWindowAttributes)
        let listed = values[2] as? [UIElementRef] ?? []
        let real = try listed.filter { try !isDesktop($0) }
        let candidates = [values[0] as? UIElementRef, values[1] as? UIElementRef, real.last]
        // Finder can report its desktop focused with a background context menu open.
        for case let window? in candidates where try !isDesktop(window) { return try windowRef(window) }
        for case let window? in [values[0] as? UIElementRef, values[1] as? UIElementRef, listed.last] { return try windowRef(window) }
        throw Errors.make("no_windows")
    }
    public func ordered(_ target: AppTarget) throws -> [ComputerUseCore.WindowRef] {
        try ((AX.backend.get(app(target), "AXWindows") as? [UIElementRef]) ?? []).map(windowRef)
    }
    public func at(_ target: AppTarget, point: CGPoint) throws -> ComputerUseCore.WindowRef {
        let listed = try ordered(target)
        if listed.isEmpty { throw Errors.make("no_windows") }
        for window in listed where point.x >= window.frame.minX && point.x < window.frame.maxX && point.y >= window.frame.minY && point.y < window.frame.maxY {
            if let hit = AX.backend.at(try app(target), x: point.x, y: point.y), try AX.backend.pid(hit) != window.pid { return try ref(hit) }
            return window
        }
        throw Errors.windowNotFound(at: point)
    }
    func ownedWindow(_ node: UIElementRef) throws -> ComputerUseCore.WindowRef? {
        let id = AX.backend.windowID(node)
        guard id != 0, let row = serverWindow(id), row.pid == (try AX.backend.pid(node)) else { return nil }
        let isWindow = try AX.backend.get(node, "AXRole") as? String == "AXWindow"
        guard let window = try isWindow ? node : AX.backend.get(node, "AXWindow") as? UIElementRef else {
            return ComputerUseCore.WindowRef(element: node, windowID: id, pid: row.pid, title: nil, frame: row.frame)
        }
        return ComputerUseCore.WindowRef(element: window, windowID: id, pid: row.pid, title: try AX.backend.get(window, "AXTitle") as? String, frame: AX.backend.frame(window) ?? row.frame)
    }
    public func ref(_ element: UIElementRef) throws -> ComputerUseCore.WindowRef {
        var node: UIElementRef? = element
        // Foreign web/file-panel elements name the host's window. Climb to an owner.
        for climbed in 0...Self.maxParents {
            guard let current = node else { break }
            if let found = try ownedWindow(current) { return found }
            if climbed == 0, let window = try AX.backend.get(current, "AXWindow") as? UIElementRef,
               try AX.backend.pid(window) == AX.backend.pid(current), let found = try ownedWindow(window) { return found }
            node = try AX.backend.get(current, "AXParent") as? UIElementRef
        }
        throw Errors.make("element_outside_app")
    }

    final class Menus {
        var watchers = 0; var observer: AXObservation?
        let heard = OSAllocatedUnfairLock(initialState: [(String, UIElementRef)]())
        var menu: UIElementRef?; var root: UIElementRef?; var kept: UIElementRef?
    }
    let lock = NSRecursiveLock()
    var menus: [pid_t: Menus] = [:]
    func state(_ target: AppTarget) -> Menus {
        lock.lock(); defer { lock.unlock() }
        let pid = target.pid ?? 0
        if let found = menus[pid] { return found }
        let found = Menus(); menus[pid] = found; return found
    }
    func keep(_ state: Menus, _ menu: UIElementRef) throws -> Bool {
        let parent = try AX.backend.get(menu, "AXParent") as? UIElementRef
        let role = try parent.flatMap { try AX.backend.get($0, "AXRole") as? String }
        if role == "AXMenuItem" { return false } // A submenu belongs to the kept menu.
        state.menu = menu; state.root = role == "AXMenuBarItem" ? parent : nil
        return true
    }
    func catchUp(_ state: Menus) throws -> Bool {
        let heard = state.heard.withLock { pending in
            let heard = pending; pending.removeAll(); return heard
        }
        var opened = false
        for (name, menu) in heard {
            if let kept = state.kept {
                if try name == Self.menuClosed || AX.same(AX.backend.get(menu, "AXParent") as? UIElementRef, kept) { continue }
                state.kept = nil // Another menu really opened and takes over.
            }
            if name == Self.menuOpened { opened = try keep(state, menu) || opened }
            else if state.menu == nil || AX.same(menu, state.menu) { state.menu = nil; state.root = nil; opened = false }
        }
        return opened
    }
    func shownBy(_ state: Menus, _ opener: UIElementRef) throws -> Bool {
        let values = try AX.backend.getMany(opener, ["AXShownMenuUIElement", "AXRole", "AXSelected", "AXChildren"])
        var shown = values[0] as? UIElementRef
        let role = values[1] as? String
        if shown == nil, Self.menuButtons.contains(role ?? "") {
            shown = try (values[3] as? [UIElementRef] ?? []).first { try AX.backend.get($0, "AXRole") as? String == "AXMenu" }
        }
        if let shown { return try keep(state, shown) }
        if role == "AXMenuBarItem", values[2] as? Bool == true { state.menu = nil; state.root = opener; return true }
        return false
    }
    func open(_ target: AppTarget) throws -> Menus {
        let s = state(target); _ = try catchUp(s)
        if [s.root, s.menu].compactMap({ $0 }).contains(where: { !AX.backend.alive($0) }) { s.menu = nil; s.root = nil }
        return s
    }
    public func openMenu(_ target: AppTarget) throws -> UIElementRef? { try open(target).root }
    public func shownMenu(_ target: AppTarget) throws -> UIElementRef? { let s = try open(target); return s.root ?? s.menu }
    public func waitForMenu(_ target: AppTarget, opener: UIElementRef) throws -> UIElementRef? {
        let s = state(target), end = system.now() + Self.menuWait
        while try !(catchUp(s) || shownBy(s, opener)) {
            if system.now() >= end { return nil }; system.sleep(Self.menuPoll)
        }
        return s.root ?? s.menu
    }
    public func keepMenu(_ target: AppTarget, title: UIElementRef) { let s = state(target); s.menu = nil; s.root = title; s.kept = title }
    public func closeMenu(_ target: AppTarget) {
        let s = state(target); lock.lock(); defer { lock.unlock() }
        s.heard.withLock { $0.removeAll() }; s.menu = nil; s.root = nil; s.kept = nil
    }
    public func watch(_ target: AppTarget) throws {
        let s = state(target); lock.lock(); s.watchers += 1; let count = s.watchers; lock.unlock()
        if count > 1 { return }
        do {
            // Snapshot only the callback's dependencies. Never capture the mutable
            // Windows/System/Menus graph on the notification run loop. Changes to
            // system.noAttention take effect on the next watch, not mid-observation.
            let backend = AX.backend, heard = s.heard, noAttention = system.noAttention
            guard let pid = target.pid else { throw Errors.make("app_not_running", ["identifier": target.path]) }
            let element = backend.app(pid: pid)
            s.observer = try backend.observe(pid: pid, element: element, names: [Self.menuOpened, Self.menuClosed] + Self.newWindows) { name, element in
                if Self.newWindows.contains(name) { noAttention(pid); return }
                heard.withLock { $0.append((name, element)) }
            }
        } catch { lock.lock(); s.watchers -= 1; lock.unlock(); throw error }
    }
    public func unwatch(_ target: AppTarget) {
        lock.lock(); guard let s = menus[target.pid ?? 0] else { lock.unlock(); return }
        s.watchers -= 1
        if s.watchers > 0 { lock.unlock(); return }
        menus.removeValue(forKey: target.pid ?? 0); lock.unlock(); s.observer?.stop()
    }
}
