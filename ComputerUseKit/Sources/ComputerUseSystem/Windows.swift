import AppKit
import ComputerUseCore
import os

/// Fresh window and menu context. Global points, top-left origin; never clamp to zero.
public final class Windows: Sendable {
    public static let maxParents = 300, menuWait = 0.25, menuPoll = 0.01
    public static let menuOpened = "AXMenuOpened", menuClosed = "AXMenuClosed"
    public static let newWindows = ["AXWindowCreated", "AXSheetCreated"]
    public static let keyWindowAttributes = ["AXFocusedWindow", "AXMainWindow", "AXWindows"]
    public static let windowListAll: UInt32 = 0 // on screen or not
    public static let desktop = "AXDesktop", menuButtons = ["AXPopUpButton", "AXMenuButton"]
    public struct Row: Equatable, Sendable {
        public var id: UInt32; public var pid: pid_t; public var title: String?; public var layer: Int; public var frame: CGRect
        public init(id: UInt32, pid: pid_t, title: String? = nil, layer: Int = 0, frame: CGRect) {
            self.id = id; self.pid = pid; self.title = title; self.layer = layer; self.frame = frame
        }
    }
    public struct System: Sendable {
        public var rows: @Sendable (UInt32, UInt32) -> [Row] = { Windows.systemRows($0, $1) }
        public var associated: @Sendable (UInt32) -> Set<UInt32> = { Windows.systemAssociated($0) }
        public var now: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        public var sleep: @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
        public var noAttention: @Sendable (pid_t) -> Void = { Focus.noAttention($0) }
        public init() {}
    }
    public let system: System
    public static let shared = Windows()
    public init(system: System = .init()) { self.system = system }
    deinit {
        let removed = watches.withLock { watches in
            let removed = Array(watches.values); watches.removeAll(); return removed
        }
        for watch in removed {
            watch.menus.close(retiring: true)
            watch.observer?.stop()
            // Keep attention delivery open through source uninstall/in-flight SDK
            // callbacks. Menu publication has already been retired independently.
            if !watch.starting { watch.notifications?.stop() }
        }
    }
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

    private struct MenuView: Sendable {
        var menu: UIElementRef?, root: UIElementRef?, kept: UIElementRef?
    }
    private final class Menus: Sendable {
        struct Record: Sendable {
            var live = true
            var revision: UInt64 = 0
            var heard: [(String, UIElementRef)] = []
            var view = MenuView()
        }
        // Per-PID execution only: target AX reads may block. Notification delivery
        // never acquires this lock, and watch/stop never hold it across a main hop.
        let execution = NSRecursiveLock()
        let record: OSAllocatedUnfairLock<Record>
        init(view: MenuView = MenuView()) { record = OSAllocatedUnfairLock(initialState: Record(view: view)) }
        @discardableResult func close(retiring: Bool = false) -> MenuView {
            let previous = record.withLock {
                let previous = $0.view
                $0.revision &+= 1; $0.view = MenuView()
                $0.heard.removeAll()
                if retiring { $0.live = false }
                return previous
            }
            return previous
        }
    }
    private final class Notifications: Sendable {
        private struct AttentionEffect: Sendable {
            let pid: pid_t
            let noAttention: @Sendable (pid_t) -> Void
            let backend: any AXBackend
            func run(_ count: Int) {
                AX.withBackend(backend) { for _ in 0..<count { noAttention(pid) } }
            }
        }
        private struct Attention: Sendable {
            var accepting = true
            var pending = 0
            var effect: AttentionEffect?
        }
        let record: OSAllocatedUnfairLock<Menus.Record>
        private let pending: OSAllocatedUnfairLock<Attention>
        private let attention: any DispatchSourceUserDataAdd
        init(record: OSAllocatedUnfairLock<Menus.Record>, pid: pid_t,
             noAttention: @escaping @Sendable (pid_t) -> Void, backend: any AXBackend) {
            self.record = record
            let effect = AttentionEffect(pid: pid, noAttention: noAttention, backend: backend)
            let pending = OSAllocatedUnfairLock(initialState: Attention(effect: effect))
            self.pending = pending
            let attention = DispatchSource.makeUserDataAddSource(queue: .global())
            self.attention = attention
            // Attention delivery is independent of the menu recorder's lifetime.
            // Capture the watch caller's backend BEFORE either worker hop.
            attention.setEventHandler {
                let count = pending.withLock { state in
                    let count = state.pending; state.pending = 0; return count
                }
                effect.run(count)
            }
            attention.resume()
        }
        deinit { attention.cancel() }
        func stop() {
            // Called only after observe failed or observer.stop completed. Retiring
            // menus earlier must not drop callbacks delivered during SDK uninstall.
            let (count, effect) = pending.withLock { state in
                state.accepting = false
                let flush = (state.pending, state.effect)
                state.pending = 0; state.effect = nil; return flush
            }
            attention.cancel()
            // Move dependency ownership out of the recorder as well: a backend may
            // retain its stopped callback context. Release it outside the lock.
            guard count > 0, let effect else { return }
            // Cancellation may discard an enqueued source handler. Claim its work
            // exactly once and flush off-main, outside locks and the AX callback.
            DispatchQueue.global().async { effect.run(count) }
        }
        func hear(_ name: String, _ element: UIElementRef) {
            if Windows.newWindows.contains(name) {
                let wake = pending.withLock { state in
                    guard state.accepting else { return false }
                    state.pending += 1; return true
                }
                if wake { attention.add(data: 1) }
                return
            }
            record.withLock { if $0.live { $0.heard.append((name, element)) } }
        }
    }
    private struct Watch: Sendable {
        let menus: Menus
        var watchers = 0
        var starting = false
        var observer: (any AXObservation)?
        var notifications: Notifications?
    }
    private let watches = OSAllocatedUnfairLock(initialState: [pid_t: Watch]())
    private func state(_ target: AppTarget) -> Menus {
        watches.withLock { watches in
            let pid = target.pid ?? 0
            if let found = watches[pid] { return found.menus }
            let found = Menus(); watches[pid] = Watch(menus: found); return found
        }
    }
    private func keep(_ view: inout MenuView, _ menu: UIElementRef) throws -> Bool {
        let parent = try AX.backend.get(menu, "AXParent") as? UIElementRef
        let role = try parent.flatMap { try AX.backend.get($0, "AXRole") as? String }
        if role == "AXMenuItem" { return false } // A submenu belongs to the kept menu.
        view.menu = menu; view.root = role == "AXMenuBarItem" ? parent : nil
        return true
    }
    private func catchUp(_ view: inout MenuView, heard: [(String, UIElementRef)]) throws -> Bool {
        var opened = false
        for (name, menu) in heard {
            if let kept = view.kept {
                if try name == Self.menuClosed || AX.same(AX.backend.get(menu, "AXParent") as? UIElementRef, kept) { continue }
                view.kept = nil // Another menu really opened and takes over.
            }
            if name == Self.menuOpened { opened = try keep(&view, menu) || opened }
            else if view.menu == nil || AX.same(menu, view.menu) { view.menu = nil; view.root = nil; opened = false }
        }
        return opened
    }
    private func shownBy(_ view: inout MenuView, _ opener: UIElementRef) throws -> Bool {
        let values = try AX.backend.getMany(opener, ["AXShownMenuUIElement", "AXRole", "AXSelected", "AXChildren"])
        var shown = values[0] as? UIElementRef
        let role = values[1] as? String
        if shown == nil, Self.menuButtons.contains(role ?? "") {
            shown = try (values[3] as? [UIElementRef] ?? []).first { try AX.backend.get($0, "AXRole") as? String == "AXMenu" }
        }
        if let shown { return try keep(&view, shown) }
        if role == "AXMenuBarItem", values[2] as? Bool == true { view.menu = nil; view.root = opener; return true }
        return false
    }
    private func update(_ s: Menus, _ work: (inout MenuView, [(String, UIElementRef)]) throws -> Bool) rethrows -> (MenuView, Bool) {
        s.execution.lock(); defer { s.execution.unlock() }
        let snapshot = s.record.withLock { record in
            let snapshot = record
            record.heard.removeAll()
            return snapshot
        }
        guard snapshot.live else { return (MenuView(), false) }
        var view = snapshot.view
        let opened = try work(&view, snapshot.heard)
        let sampled = view
        return s.record.withLock { record in
            // close/unwatch or same-thread reentry can invalidate an AX sample.
            guard record.live, record.revision == snapshot.revision else { return (record.view, false) }
            record.view = sampled; record.revision &+= 1
            return (sampled, opened)
        }
    }
    private func open(_ target: AppTarget) throws -> MenuView {
        try update(state(target)) { view, heard in
            _ = try catchUp(&view, heard: heard)
            if [view.root, view.menu].compactMap({ $0 }).contains(where: { !AX.backend.alive($0) }) { view.menu = nil; view.root = nil }
            return false
        }.0
    }
    public func openMenu(_ target: AppTarget) throws -> UIElementRef? { try open(target).root }
    public func shownMenu(_ target: AppTarget) throws -> UIElementRef? { let s = try open(target); return s.root ?? s.menu }
    public func waitForMenu(_ target: AppTarget, opener: UIElementRef) throws -> UIElementRef? {
        let end = system.now() + Self.menuWait
        while true {
            // A callback can unwatch/rewatch during AX or sleep. Follow the live
            // generation instead of polling a permanently retired recorder.
            let (view, opened) = try update(state(target)) { view, heard in
                try catchUp(&view, heard: heard) || shownBy(&view, opener)
            }
            if opened { return view.root ?? view.menu }
            if system.now() >= end { return nil }; system.sleep(Self.menuPoll)
        }
    }
    public func keepMenu(_ target: AppTarget, title: UIElementRef) {
        let s = state(target)
        s.record.withLock { $0.revision &+= 1; $0.view = MenuView(root: title, kept: title) }
    }
    public func closeMenu(_ target: AppTarget) { state(target).close() }
    public func watch(_ target: AppTarget) throws {
        // Joining a pending registration is nonblocking, as before: in particular
        // main must stay available to install its run-loop source. A failed first
        // registration retires its recorder but retains successful joiners' counts;
        // the next watch can retry registration even with those claims outstanding.
        let s = watches.withLock { watches -> Menus? in
            let pid = target.pid ?? 0
            var watch = watches[pid] ?? Watch(menus: Menus())
            watch.watchers += 1
            let start = !watch.starting && watch.observer == nil
            if start { watch.starting = true }
            watches[pid] = watch
            return start ? watch.menus : nil
        }
        guard let s else { return }
        do {
            let backend = AX.backend
            guard let pid = target.pid else { throw Errors.make("app_not_running", ["identifier": target.path]) }
            let notifications = Notifications(record: s.record, pid: pid, noAttention: system.noAttention, backend: backend)
            let starting = watches.withLock { watches in
                guard var watch = watches[pid], watch.menus === s else { return false }
                watch.notifications = notifications; watches[pid] = watch; return true
            }
            guard starting else { notifications.stop(); return }
            let observer: any AXObservation
            do {
                observer = try backend.observe(pid: pid, element: backend.app(pid: pid), names: [Self.menuOpened, Self.menuClosed] + Self.newWindows) { name, element in
                    notifications.hear(name, element)
                }
            } catch {
                // Pending teardown may already have removed this generation. A
                // failed creation still owns closing/flushing its notification seam.
                notifications.stop()
                throw error
            }
            let published = watches.withLock { watches in
                guard var watch = watches[pid], watch.menus === s else { return false }
                watch.starting = false; watch.observer = observer; watches[pid] = watch
                return true
            }
            if !published { observer.stop(); notifications.stop() }
        } catch {
            let removed = watches.withLock { watches -> Watch? in
                let pid = target.pid ?? 0
                guard let watch = watches[pid], watch.menus === s else { return nil }
                let view = s.close(retiring: true)
                if watch.watchers > 1 {
                    watches[pid] = Watch(menus: Menus(view: view), watchers: watch.watchers - 1)
                } else { watches.removeValue(forKey: pid) }
                return watch
            }
            removed?.notifications?.stop()
            throw error
        }
    }
    public func unwatch(_ target: AppTarget) {
        let removed = watches.withLock { watches -> Watch? in
            let pid = target.pid ?? 0
            guard var watch = watches[pid], watch.watchers > 0 else { return nil }
            watch.watchers -= 1
            if watch.watchers > 0 { watches[pid] = watch; return nil }
            return watches.removeValue(forKey: pid)
        }
        // No registry/state/execution lock spans stop (which may hop to main or
        // reenter watch). In-flight menu callbacks only reach the retired recorder;
        // attention acceptance remains open until source uninstall finishes.
        removed?.menus.close(retiring: true)
        removed?.observer?.stop()
        // A pending observe still owns cleanup: once it returns, it will stop the
        // stale observer and then flush attention accepted through that stop.
        if removed?.starting == false { removed?.notifications?.stop() }
    }
}
