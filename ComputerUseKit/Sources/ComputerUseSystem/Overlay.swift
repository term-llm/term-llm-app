import AppKit
import ComputerUseCore
import QuartzCore

/// In-process replacement for upstream's datagram drawing process. AppKit work is
/// confined to the helper's main thread; Core Animation plays sampled pointer
/// spring/press/fade frames independently while tool workers are busy.
@MainActor
public final class Overlay {
    public nonisolated static let shared = Overlay()
    public nonisolated static let accent = NSColor(srgbRed: 1, green: 127.0 / 255, blue: 39.0 / 255, alpha: 1)
    public nonisolated static func enabled(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> Bool
    {
        !["0", "false", "no", "off"].contains(
            (environment["TERM_LLM_COMPUTER_POINTER"] ?? "").lowercased())
    }
    private var scene: OverlayScene?
    private var pointer: NSPanel?, flash: NSPanel?, halo: NSPanel?
    private var node: NSView?, picture: NSImageView?, glass: NSVisualEffectView?
    private var pollTimer: Timer?, expiry: Timer?
    private var observers: [NSObjectProtocol] = []
    private var screens: [CGRect] = [], area = CGRect.zero
    public nonisolated init() {}
    // Runs on the main thread; a release elsewhere hops there first, as the windows need.
    isolated deinit {
        for timer in [pollTimer, expiry] { timer?.invalidate() }
        for panel in [pointer, flash, halo] { panel?.orderOut(nil) }
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
    public nonisolated func send(_ command: OverlayCommand) {
        guard Self.enabled(), command.valid else { return }
        MainThread.onMain { [self] in
            // MainThread's no-runloop fallback is useful for pure tests, but must
            // never construct an AppKit window on a test/worker thread.
            guard Thread.isMainThread, MainThread.isRunning else { return }
            MainActor.assumeIsolated { self.command(command) }
        }
    }
    private func command(_ command: OverlayCommand) {
        let now = ProcessInfo.processInfo.systemUptime
        if scene == nil {
            switch command {
            case .move, .flash, .halo: break
            default: return
            }
            scene = OverlayScene(now: now)
            setup()
        }
        screens = OverlayGeometry.flipScreens(NSScreen.screens.map(\.frame))
        guard !screens.isEmpty, let scene else { return }
        area = screens.reduce(CGRect.null) { $0.union($1) }
        pointer?.setFrame(
            OverlayGeometry.windowFrame(area, primaryHeight: NSScreen.screens[0].frame.maxY),
            display: true)
        scene.command(
            command, now: now, screens: screens,
            calm: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        animate(now: now)
        restack()
        marks(now: now)
        pollTimer?.invalidate()
        // Both timers are scheduled on the main run loop, so they fire on the main thread.
        pollTimer = Timer(timeInterval: OverlayGeometry.poll, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.restack()
                self.marks(now: now)
            }
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
        expiry?.invalidate()
        let remaining = max(
            0.01, scene.track.touched + scene.track.idle + OverlayGeometry.fade - now)
        expiry = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        RunLoop.main.add(expiry!, forMode: .common)
    }
    private static func panel() -> NSPanel {
        let made = PresencePanel(
            contentRect: CGRect(x: 0, y: 0, width: 112, height: 112),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        made.title = "\(product) Pointer"
        made.isOpaque = false
        made.backgroundColor = .clear
        made.hasShadow = false
        made.ignoresMouseEvents = true
        made.hidesOnDeactivate = false
        made.isReleasedWhenClosed = false
        made.animationBehavior = .none
        made.level = NSWindow.Level(rawValue: OverlayGeometry.level)
        made.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
        ]
        return made
    }
    private func setup() {
        pointer = Self.panel()
        flash = Self.panel()
        halo = Self.panel()
        let content = FlippedView(frame: CGRect(x: 0, y: 0, width: 112, height: 112))
        content.wantsLayer = true
        content.autoresizingMask = [.width, .height]
        pointer?.contentView = content
        let node = FlippedView(frame: CGRect(x: 0, y: 0, width: 112, height: 112))
        node.wantsLayer = true
        content.addSubview(node)
        self.node = node
        let glass = NSVisualEffectView(frame: node.bounds)
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.isHidden = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let mask = CALayer()
        mask.frame = glass.bounds
        mask.contents = Self.pointerImage(coverOnly: true)
        glass.layer?.mask = mask
        node.addSubview(glass)
        self.glass = glass
        let picture = NSImageView(frame: node.bounds)
        picture.wantsLayer = true
        picture.image = Self.pointerImage()
        node.addSubview(picture)
        self.picture = picture
        for name in [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didActivateApplicationNotification,
        ] {
            observers.append(
                NSWorkspace.shared.notificationCenter.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.restack() } })  // queue: .main
        }
    }
    private func animate(now: Double) {
        guard let scene, let layer = node?.layer, let frame = scene.track.frame(now) else { return }
        // Sample the exact upstream pure state. The render server interpolates
        // between these keys; no per-frame main-thread timer or image rasterization.
        let duration = max(
            0.001, scene.track.touched + scene.track.idle + OverlayGeometry.fade - now)
        let steps = max(1, Int(ceil(duration * 60)))
        var positions: [NSValue] = []
        var transforms: [NSValue] = []
        var opacity: [NSNumber] = []
        var blur: [NSNumber] = []
        for i in 0...steps {
            let time = now + duration * Double(i) / Double(steps)
            let f =
                scene.track.frame(time)
                ?? PointerTrack.Frame(
                    point: scene.track.move?.end ?? frame.point, shape: Pointer.rest, press: 1,
                    opacity: 0,
                    blur: 0, wake: 0, fill: frame.fill)
            positions.append(
                NSValue(point: CGPoint(x: f.point.x - area.minX, y: f.point.y - area.minY)))
            transforms.append(
                NSValue(caTransform3D: Self.transform(shape: f.shape, press: f.press)))
            opacity.append(NSNumber(value: f.opacity))
            blur.append(NSNumber(value: f.blur))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAllAnimations()
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = positions.last!.pointValue
        layer.transform = transforms.last!.caTransform3DValue
        layer.opacity = 0
        picture?.image = Self.pointerImage(fill: frame.fill)
        let filter = CIFilter(name: "CIGaussianBlur")
        filter?.name = "showBlur"
        filter?.setValue(0, forKey: kCIInputRadiusKey)
        picture?.layer?.filters = filter.map { [$0] }
        for (key, values) in [
            ("position", positions as [Any]), ("transform", transforms as [Any]),
            ("opacity", opacity as [Any]),
        ] {
            let animation = CAKeyframeAnimation(keyPath: key)
            animation.values = values
            animation.duration = duration
            animation.calculationMode = .linear
            layer.add(animation, forKey: key)
        }
        let sharpen = CAKeyframeAnimation(keyPath: "filters.showBlur.inputRadius")
        sharpen.values = blur
        sharpen.duration = duration
        picture?.layer?.add(sharpen, forKey: "sharpen")
        CATransaction.commit()
    }
    public nonisolated static func transform(shape: Pointer.Shape, press: Double) -> CATransform3D {
        var t = CGAffineTransform(translationX: Pointer.pivot.x, y: Pointer.pivot.y)
        t = t.rotated(by: shape.a * .pi / 180).scaledBy(x: shape.sx, y: shape.sy).rotated(
            by: shape.b * .pi / 180)
        t = t.translatedBy(
            x: Pointer.pressAnchor.x - Pointer.pivot.x, y: Pointer.pressAnchor.y - Pointer.pivot.y
        ).scaledBy(x: press, y: press).translatedBy(
            x: -Pointer.pressAnchor.x, y: -Pointer.pressAnchor.y)
        return CATransform3DMakeAffineTransform(t)
    }
    private func restack() {
        guard let scene else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let windows = Self.windows()
        let place = scene.track.move.flatMap {
            OverlayGeometry.stacking(
                $0.end, pid: scene.pid,
                frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                windows: windows,
                window: scene.window)
        }
        order(pointer, place: place)
        order(
            flash,
            place: scene.flash.alive(now)
                ? place.map {
                    OverlayGeometry.Place(
                        level: $0.level, window: pointer?.windowNumber ?? $0.window)
                } : nil, below: true)
        order(halo, place: scene.halo.follow(windows, now: now))
    }
    private func order(_ panel: NSPanel?, place: OverlayGeometry.Place?, below: Bool = false) {
        guard let panel else { return }
        guard let place else {
            panel.orderOut(nil)
            return
        }
        panel.level = NSWindow.Level(rawValue: place.level)
        panel.order(below ? .below : .above, relativeTo: place.window)
    }
    private func marks(now: Double) {
        guard let scene, let primary = NSScreen.screens.first else { return }
        for (mark, panel, width, radius) in [
            (scene.flash, flash, 2.0, 4.0), (scene.halo, halo, 3.0, 16.0),
        ] {
            guard let panel, let box = mark.box else { continue }
            let frame = OverlayGeometry.windowFrame(
                OverlayGeometry.grow(box, by: width), primaryHeight: primary.frame.maxY)
            if panel.frame != frame || panel.contentView?.layer == nil {
                panel.setFrame(frame, display: true)
                let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
                view.wantsLayer = true
                let stroke = CAShapeLayer()
                stroke.frame = view.bounds
                stroke.path = CGPath(
                    roundedRect: view.bounds.insetBy(dx: width / 2, dy: width / 2),
                    cornerWidth: radius + width / 2, cornerHeight: radius + width / 2,
                    transform: nil)
                stroke.fillColor = NSColor.clear.cgColor
                stroke.strokeColor = Self.accent.cgColor
                stroke.lineWidth = width
                view.layer?.addSublayer(stroke)
                panel.contentView = view
            }
            // Fades are CA animations, not alphaValue updates at the poll rate.
            guard let layer = panel.contentView?.layer else { continue }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let length = max(0.001, mark.until + OverlayGeometry.fade - now)
            let steps = max(1, Int(ceil(length * 60)))
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = (0...steps).map {
                NSNumber(value: mark.alpha(now + length * Double($0) / Double(steps)))
            }
            animation.duration = length
            layer.opacity = 0
            layer.add(animation, forKey: "fade")
            CATransaction.commit()
        }
    }
    private nonisolated static func windows() -> [OverlayGeometry.Window] {
        let rows =
            CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
            ?? []
        return rows.compactMap { row in
            guard let id = row[kCGWindowNumber as String] as? Int,
                let pid = row[kCGWindowOwnerPID as String] as? Int32,
                let level = row[kCGWindowLayer as String] as? Int,
                let box = row[kCGWindowBounds as String] as? [String: Double], let x = box["X"],
                let y = box["Y"], let w = box["Width"], let h = box["Height"]
            else { return nil }
            return OverlayGeometry.Window(
                id: id, pid: pid, level: level, bounds: CGRect(x: x, y: y, width: w, height: h))
        }
    }
    private func hide() {
        pointer?.orderOut(nil)
        flash?.orderOut(nil)
        halo?.orderOut(nil)
        pollTimer?.invalidate()
        pollTimer = nil
        expiry?.invalidate()
        expiry = nil
        scene = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
        pointer = nil
        flash = nil
        halo = nil
        node = nil
        glass = nil
        picture = nil
    }
    /// Paint × cover: black fog tint, white arrow fill and rim; cover is solid
    /// inside the arrow and the sampled radial fog outside. No bundled resources.
    public nonisolated static func pointerImage(coverOnly: Bool = false, fill: Double = Pointer.fill) -> NSImage
    {
        NSImage(size: CGSize(width: 112, height: 112), flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            cg.saveGState()
            defer { cg.restoreGState() }
            cg.translateBy(x: 56, y: 56)
            let arrow = NSBezierPath()
            let points = Pointer.outlinePoints()
            arrow.move(to: points[0])
            for p in points.dropFirst() { arrow.line(to: p) }
            arrow.close()
            if !coverOnly {
                cg.beginTransparencyLayer(auxiliaryInfo: nil)
                NSColor.black.withAlphaComponent(Pointer.tint).setFill()
                NSBezierPath(ovalIn: CGRect(x: -36, y: -36, width: 72, height: 72)).fill()
                NSColor.white.withAlphaComponent(fill).setFill()
                arrow.fill()
                NSColor.white.withAlphaComponent(Pointer.rim).setStroke()
                arrow.lineWidth = Pointer.rimWidth
                arrow.miterLimit = 10
                arrow.stroke()
                cg.setBlendMode(.destinationIn)
                cg.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            let colors = Pointer.fogAlphas.map { NSColor.white.withAlphaComponent($0) }
            let locations = Pointer.fogAlphas.indices.map { CGFloat($0) / 9 }
            if let gradient = NSGradient(colors: colors, atLocations: locations, colorSpace: .sRGB)
            {
                gradient.draw(
                    fromCenter: .zero, radius: 0, toCenter: .zero, radius: 36, options: [])
            }
            NSColor.white.setFill()
            arrow.fill()
            if !coverOnly {
                cg.endTransparencyLayer()
                cg.endTransparencyLayer()
            }
            return true
        }
    }
}
private final class FlippedView: NSView { override var isFlipped: Bool { true } }
