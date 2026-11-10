import CoreGraphics
import Foundation

/// Geometry and time-dependent overlay state, independent of AppKit and clocks.
public enum OverlayGeometry {
    public static let size = 112.0, level = 102, idle = 30.0, fade = 0.44, showBlur = 7.0
    public static let pressGap = 0.1, active = 10.0, poll = 0.1, done = 2.0, paused = 0.5
    public static let rock = 10.0, swing = 0.685, rockFrame = 1.0 / 30, loadingFill = 0.24
    public static func ease(_ u: Double) -> Double { u * u * (3 - 2 * u) }
    public static func grow(_ box: CGRect, by: Double) -> CGRect { box.insetBy(dx: -by, dy: -by) }
    public static func holds(_ box: CGRect, _ point: CGPoint) -> Bool {
        point.x >= box.minX && point.x < box.maxX && point.y >= box.minY && point.y < box.maxY
    }
    /// No outline around nothing or over half a window: that large marks nothing.
    public static func flashBox(_ frame: CGRect, within: CGRect?) -> CGRect? {
        let area = max(frame.size.width, 0) * max(frame.size.height, 0)
        if area == 0 || within.map({ area > $0.width * $0.height / 2 }) == true { return nil }
        return frame
    }
    public static func flipScreens(_ frames: [CGRect]) -> [CGRect] {
        guard let top = frames.first?.maxY else { return [] }
        return frames.map {
            CGRect(x: $0.minX, y: top - $0.maxY, width: $0.width, height: $0.height)
        }
    }
    /// Union only screens holding an endpoint; all screens when none does.
    public static func bounds(of screens: [CGRect], points: [CGPoint]) -> CGRect {
        let held = screens.filter { box in points.contains { holds(box, $0) } }
        return (held.isEmpty ? screens : held).reduce(CGRect.null) { $0.union($1) }
    }
    public static func windowFrame(_ box: CGRect, primaryHeight: Double) -> CGRect {
        CGRect(x: box.minX, y: primaryHeight - box.maxY, width: box.width, height: box.height)
    }
    public static func windowOrigin(_ point: CGPoint, primaryHeight: Double) -> CGPoint {
        windowFrame(
            CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size),
            primaryHeight: primaryHeight
        ).origin
    }
    public struct Window: Equatable {
        public var id: Int, pid: Int32, level: Int, bounds: CGRect
        public init(id: Int, pid: Int32, level: Int, bounds: CGRect) {
            self.id = id
            self.pid = pid
            self.level = level
            self.bounds = bounds
        }
    }
    public struct Place: Equatable {
        public var level: Int, window: Int
        public init(level: Int, window: Int) {
            self.level = level
            self.window = window
        }
    }
    public static func targetWindow(
        _ point: CGPoint, pid: Int32?, windows: [Window], window: Int = 0
    )
        -> Window?
    {
        windows.first {
            $0.id == window || (window == 0 && $0.pid == pid && holds($0.bounds, point))
        }
    }
    /// Front app: above menus. Background: just over its window, so other apps
    /// covering the target also cover the pointer. No target on this Space: hide.
    public static func stacking(
        _ point: CGPoint, pid: Int32?, frontmost: Int32?, windows: [Window], window: Int = 0
    ) -> Place? {
        if pid == nil || pid == frontmost { return Place(level: level, window: 0) }
        return targetWindow(point, pid: pid, windows: windows, window: window).map {
            Place(level: $0.level, window: $0.id)
        }
    }
}

public enum OverlayCommand: Sendable {
    case move(CGPoint, pid: Int32? = nil, window: Int = 0, animate: Bool = true)
    case press(Int)
    case activity(String)
    case flash(CGRect, within: CGRect? = nil, pid: Int32? = nil, window: Int = 0)
    case halo(CGRect, pid: Int32? = nil, window: Int = 0)
    case done
    public var valid: Bool {
        func point(_ p: CGPoint) -> Bool { p.x.isFinite && p.y.isFinite }
        func box(_ r: CGRect) -> Bool { point(r.origin) && r.width.isFinite && r.height.isFinite }
        switch self {
        case .move(let p, _, _, _): return point(p)
        case .flash(let r, let within, _, _): return box(r) && (within.map(box) ?? true)
        case .halo(let r, _, _): return box(r)
        case .press(let count): return (1...100).contains(count)
        case .activity(let s): return ["idle", "loading", "paused"].contains(s)
        case .done: return true
        }
    }
}

public final class PointerTrack {
    public struct Frame {
        public var point: CGPoint, shape: Pointer.Shape, press: Double, opacity: Double,
            blur: Double,
            wake: Double, fill: Double
        public init(
            point: CGPoint, shape: Pointer.Shape, press: Double, opacity: Double, blur: Double,
            wake: Double, fill: Double
        ) {
            self.point = point
            self.shape = shape
            self.press = press
            self.opacity = opacity
            self.blur = blur
            self.wake = wake
            self.fill = fill
        }
    }
    public let idle: Double
    public var touched: Double, shown: Double?, move: Pointer.Move?, began = 0.0,
        pulses: [Double] = [], activity = "idle", since: Double
    public init(now: Double, idle: Double = OverlayGeometry.idle) {
        touched = now
        since = now
        self.idle = idle
    }
    public func go(_ target: CGPoint, now: Double, screens: [CGRect], animate: Bool = true) {
        let here = move.map { Pointer.pose($0, now - began).point }
        let bounds = OverlayGeometry.bounds(of: screens, points: [target, here ?? target])
        guard !bounds.isNull else { return }
        let end = CGPoint(
            x: Pointer.clamp(target.x, bounds.minX, bounds.maxX),
            y: Pointer.clamp(target.y, bounds.minY, bounds.maxY))
        if here == nil { shown = now }
        // The same target again leaves a running move alone.
        if move == nil || Pointer.distance(move!.end, end) >= Pointer.still {
            move = Pointer.plan(animate ? here ?? end : end, end, bounds: bounds)
            began = now
            // A pulse not yet played was for the old target.
            pulses.removeAll { $0 > now }
        }
        touched = now
    }
    public func lands(_ now: Double) -> Double {
        max(now, began + (move?.arrive ?? 0), (shown ?? now) + OverlayGeometry.fade)
    }
    public func press(_ count: Int, now: Double) {
        if shown != nil {
            pulses = (0..<max(0, count)).map { lands(now) + Double($0) * OverlayGeometry.pressGap }
        }
        touched = now
    }
    public func act(_ state: String, now: Double) {
        if state != activity {
            activity = state
            since = now
        }
    }
    public func frame(_ now: Double) -> Frame? {
        let g = OverlayGeometry.self
        let left = touched + idle + g.fade - now
        if left <= 0 { return nil }
        guard let shown, let move else {
            return Frame(
                point: .zero, shape: Pointer.rest, press: 1, opacity: 0, blur: 0, wake: left,
                fill: Pointer.fill)
        }
        let pose = Pointer.pose(move, now - began)
        let press = pulses.map { Pointer.pressScale(now - $0) }.min() ?? 1
        let sharp = g.ease(Pointer.clamp((now - shown) / g.fade))
        let opacity = min(sharp, g.ease(Pointer.clamp(left / g.fade)))
        let ends =
            [began + move.duration, shown + g.fade] + pulses.map { $0 + Pointer.pressTimes.last! }
        let end = ends.max()!
        let rest = max(end, since)
        var frame = Frame(
            point: CGPoint(
                x: pose.point.x.rounded(.toNearestOrEven), y: pose.point.y.rounded(.toNearestOrEven)
            ),
            shape: pose.shape, press: press, opacity: opacity, blur: g.showBlur * (1 - sharp),
            wake: now < end || left < g.fade ? 0 : left - g.fade, fill: Pointer.fill)
        if activity == "paused" { frame.opacity *= g.paused }
        if activity == "loading" {
            frame.fill = g.loadingFill
            if now >= rest {
                frame.shape = Pointer.Shape(a: g.rock * sin(Double.pi * (now - rest) / g.swing))
                frame.wake = min(frame.wake, g.rockFrame)
            }
        }
        return frame
    }
}

public final class OverlayMark {
    public var box: CGRect?, since = 0.0, until = 0.0, pid: Int32?, window = 0
    public init() {}
    public func show(
        _ box: CGRect?, now: Double, until: Double, appear: Double = OverlayGeometry.fade
    ) {
        if appear == 0 || !alive(now) { since = now - (OverlayGeometry.fade - appear) }
        self.box = box
        self.until = until
    }
    public func alive(_ now: Double) -> Bool { box != nil && now < until + OverlayGeometry.fade }
    public func alpha(_ now: Double) -> Double {
        guard alive(now) else { return 0 }
        return min(
            OverlayGeometry.ease(Pointer.clamp((now - since) / OverlayGeometry.fade)),
            OverlayGeometry.ease(
                Pointer.clamp((until + OverlayGeometry.fade - now) / OverlayGeometry.fade)))
    }
    public func follow(_ windows: [OverlayGeometry.Window], now: Double) -> OverlayGeometry.Place? {
        guard alive(now), let box,
            let target = OverlayGeometry.targetWindow(
                CGPoint(x: box.midX, y: box.midY), pid: pid, windows: windows, window: window)
        else { return nil }
        self.box = target.bounds
        return OverlayGeometry.Place(level: target.level, window: target.id)
    }
    public func wake(_ now: Double) -> Double {
        if !alive(now) { return .infinity }
        return now < since + OverlayGeometry.fade || now >= until ? 0 : until - now
    }
}

public final class OverlayScene {
    public let track: PointerTrack, flash = OverlayMark(), halo = OverlayMark()
    public var pid: Int32?, window = 0
    public init(now: Double, idle: Double = OverlayGeometry.idle) {
        track = PointerTrack(now: now, idle: idle)
    }
    public func command(
        _ command: OverlayCommand, now: Double, screens: [CGRect], calm: Bool = false
    ) {
        guard command.valid else { return }
        switch command {
        case .done:
            halo.until = min(halo.until, now)
            track.touched = min(track.touched, now + OverlayGeometry.done - track.idle)
            return
        case .move(let p, let pid, let window, let animate):
            self.pid = pid
            self.window = window
            track.go(p, now: now, screens: screens, animate: animate && !calm)
        case .flash(let frame, let within, let pid, let window):
            if track.move == nil || !OverlayGeometry.holds(frame, track.move!.end) {
                self.pid = pid
                self.window = window
                track.go(
                    CGPoint(x: frame.midX, y: frame.midY), now: now, screens: screens,
                    animate: !calm)
            }
            flash.show(
                OverlayGeometry.flashBox(frame, within: within), now: now,
                until: track.lands(now) + Pointer.pressTimes.last!, appear: 0)
        case .halo(let frame, let pid, let window):
            halo.pid = pid
            halo.window = window
            halo.show(frame, now: now, until: now + OverlayGeometry.active)
        case .press(let count): track.press(count, now: now)
        case .activity(let state): track.act(state, now: now)
        }
        track.touched = now
    }
    public func wake(_ now: Double, frame: PointerTrack.Frame) -> Double {
        min(
            frame.wake, flash.wake(now), halo.wake(now),
            halo.alive(now) ? OverlayGeometry.poll : .infinity)
    }
}
