import AppKit
import ComputerUseCore

/// Visible while calls run and for three seconds afterwards. Only observes Esc:
/// local monitoring returns the original event and global monitoring steals none.
public final class ActivityBanner {
    public static let shared = ActivityBanner()
    public static let text = "term-llm is using your computer · Esc to stop"
    private let callbackLock = NSLock()
    private var callback: (() -> Void)?
    public var onStop: (() -> Void)? {
        get {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            return callback
        }
        set {
            callbackLock.lock()
            callback = newValue
            callbackLock.unlock()
        }
    }
    private var state = ActivityWindow(), panel: NSPanel?, timer: Timer?, global: Any?, local: Any?
    public init() {}
    deinit {
        let global = global
        let local = local
        let panel = panel
        let timer = timer
        let cleanup = {
            timer?.invalidate()
            panel?.orderOut(nil)
            if let global { NSEvent.removeMonitor(global) }
            if let local { NSEvent.removeMonitor(local) }
        }
        if Thread.isMainThread { cleanup() } else { DispatchQueue.main.async(execute: cleanup) }
    }
    public func update(working: Bool) {
        MainThread.onMain {
            guard Thread.isMainThread, MainThread.isRunning else { return }
            self.state.update(working: working, now: ProcessInfo.processInfo.systemUptime)
            self.refresh()
        }
    }
    /// Pure event gate, testable without creating windows or installing monitors.
    public static func isStopKey(code: UInt16, tag: Int64) -> Bool {
        code == 53 && tag != Events.ownTag
    }
    private func observe(_ event: NSEvent) {
        let tag =
            event.cgEvent?.getIntegerValueField(CGEventField(rawValue: Events.userDataField)!) ?? 0
        if state.visible(now: ProcessInfo.processInfo.systemUptime)
            && Self.isStopKey(code: event.keyCode, tag: tag)
        {
            onStop?()
        }
    }
    private func refresh() {
        timer?.invalidate()
        timer = nil
        let now = ProcessInfo.processInfo.systemUptime
        guard state.visible(now: now) else {
            hide()
            return
        }
        if panel == nil {
            let made = PresencePanel(
                contentRect: CGRect(x: 0, y: 0, width: 440, height: 38),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            made.isOpaque = false
            made.backgroundColor = .clear
            made.hasShadow = true
            made.ignoresMouseEvents = true
            made.hidesOnDeactivate = false
            made.isReleasedWhenClosed = false
            made.level = NSWindow.Level(rawValue: OverlayGeometry.level)
            made.collectionBehavior = [
                .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
            ]
            let view = NSView(frame: made.contentView!.bounds)
            view.wantsLayer = true
            view.layer?.cornerRadius = 12
            view.layer?.backgroundColor =
                NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
            view.layer?.borderWidth = 1.5
            view.layer?.borderColor = Overlay.accent.cgColor
            let label = NSTextField(labelWithString: Self.text)
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = .labelColor
            label.sizeToFit()
            label.setFrameOrigin(CGPoint(x: 16, y: (38 - label.frame.height) / 2))
            view.addSubview(label)
            made.contentView = view
            panel = made
        }
        if let screen = NSScreen.screens.first, let panel {
            panel.setFrameOrigin(
                CGPoint(
                    x: screen.visibleFrame.midX - panel.frame.width / 2,
                    y: screen.visibleFrame.maxY - panel.frame.height - 12))
            panel.orderFrontRegardless()
        }
        if global == nil {
            global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] in
                self?.observe($0)
            }
        }
        if local == nil {
            local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.observe(event)
                return event
            }
        }
        if !state.working {
            timer = Timer(
                timeInterval: max(0.01, state.remaining(now: now)), repeats: false
            ) { [weak self] _ in self?.refresh() }
            if let timer { RunLoop.main.add(timer, forMode: .common) }
        }
    }
    private func hide() {
        panel?.orderOut(nil)
        if let global {
            NSEvent.removeMonitor(global)
            self.global = nil
        }
        if let local {
            NSEvent.removeMonitor(local)
            self.local = nil
        }
    }
    public func stop() {
        MainThread.onMain {
            self.timer?.invalidate()
            self.timer = nil
            self.hide()
        }
    }
    // HelperServer aggregates concurrent calls; ComputerUseRuntime wires onStop
    // to the same stopCurrentTurn path as the human stop control.
}
