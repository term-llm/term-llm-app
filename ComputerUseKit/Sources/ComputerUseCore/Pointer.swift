import CoreGraphics
import Foundation

/// The drawn pointer: its shape and motion. Pure numbers, no clock or drawing.
/// Units are points, origin the click point, x right/y down; angles clockwise.
public enum Pointer {
    public typealias Curve = [CGPoint]  // start, two handles, end
    public static let tip = CGPoint(x: -4.95, y: -5), wing = CGPoint(x: 11.55, y: 0.7)
    public static let notch = CGPoint(x: 3.95, y: 4.35), tail = CGPoint(x: 0.5, y: 12.3)
    public static let fill = 0.16, rim = 0.8, tint = 0.37, rimWidth = 1.5, fogRadius = 36.0
    public static let fogAlphas = [
        0.786, 0.751, 0.658, 0.526, 0.371, 0.228, 0.125, 0.057, 0.022, 0.0,
    ]
    public static let pivot = CGPoint(x: 1.4, y: 2), pressAnchor = CGPoint(x: -2.7, y: -2.7)
    public static let pressTimes = [0.0, 0.025, 0.05, 0.075, 0.1, 0.15, 0.2, 0.25, 0.3]
    public static let pressScales = [1.0, 0.971, 0.913, 0.881, 0.887, 0.933, 0.972, 0.992, 1.0]
    public static let heading = -44.0 * Double.pi / 180
    public static let u = CGPoint(x: sin(heading), y: -cos(heading))
    public static let uAngle = atan2(u.y, u.x) * 180 / Double.pi
    public static let still = 0.5, hopMax = 196.0, hopResponse = 0.24, hopDamping = 0.84
    public static let glideDamping = 0.9, scaler = 0.7, responseMin = 0.12, responseMax = 2.2
    public static let startHandle = 0.41960295031576633, endHandle = 0.15
    public static let arcSize = 0.2765523188064277, arcFlow = 0.5783555327868779
    public static let margin = 20.0, samples = 24, stretch = 0.38, squash = 0.18
    public static let tiltMax = 76.0, thinMax = 1.5, thinSpeed = 3000.0, tailTime = 1.4,
        frame = 1.0 / 60
    public struct Shape: Equatable, Sendable {
        public var a: Double, sx: Double, sy: Double, b: Double
        public init(a: Double = 0, sx: Double = 1, sy: Double = 1, b: Double = 0) {
            self.a = a
            self.sx = sx
            self.sy = sy
            self.b = b
        }
    }
    public static let rest = Shape()
    public struct Move {
        public var mode = "still"
        public var start: CGPoint, end: CGPoint
        public var path: [Curve] = []
        public var response = 0.0, damping = 0.0, duration = 0.0, arrive = 0.0
        public init(start: CGPoint, end: CGPoint) {
            self.start = start
            self.end = end
        }
    }
    public static func clamp(_ v: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double {
        max(lo, min(hi, v))
    }
    public static func add(_ p: CGPoint, _ v: CGPoint, _ k: Double = 1) -> CGPoint {
        CGPoint(x: p.x + v.x * k, y: p.y + v.y * k)
    }
    public static func distance(_ p: CGPoint, _ q: CGPoint) -> Double {
        hypot(p.x - q.x, p.y - q.y)
    }
    public static func toward(_ p: CGPoint, _ q: CGPoint) -> CGPoint {
        add(q, p, -1).applying(CGAffineTransform(scaleX: 1 / distance(p, q), y: 1 / distance(p, q)))
    }
    public static func interpolate(_ rows: [(Double, Double)], _ key: Double) -> Double {
        for i in 1..<rows.count where key < rows[i].0 {
            let (k0, v0) = rows[i - 1]
            let (k1, v1) = rows[i]
            return v0 + (v1 - v0) * clamp((key - k0) / (k1 - k0))
        }
        return rows.last!.1
    }
    public static func pressScale(_ t: Double) -> Double {
        interpolate(Array(zip(pressTimes, pressScales)), t)
    }
    public static func outlinePoints(chords: Int = 6) -> [CGPoint] {
        let corners: [(CGPoint, Double)] = [(tip, 1.6), (wing, 1.6), (notch, 0), (tail, 1.6)]
        var points: [CGPoint] = []
        for i in corners.indices {
            let (corner, radius) = corners[i]
            let a = toward(corners[i].0, corners[(i + 3) % 4].0)
            let b = toward(corners[i].0, corners[(i + 1) % 4].0)
            let half = Double(acos(a.x * b.x + a.y * b.y)) / 2
            let inward = toward(.zero, add(a, b))
            let centre = add(corner, inward, radius / sin(half))
            let spokes = [a, b].map { add(add(.zero, $0, cos(half)), inward, -1) }
            let first = atan2(spokes[0].y, spokes[0].x)
            let last = atan2(spokes[1].y, spokes[1].x)
            let sweep = modulo(last - first + Double.pi, 2 * Double.pi) - Double.pi
            for k in 0..<(radius == 0 ? 1 : chords + 1) {
                let turn = first + sweep * Double(k) / Double(chords)
                points.append(add(centre, CGPoint(x: cos(turn), y: sin(turn)), radius))
            }
        }
        return points
    }
    static func modulo(_ x: Double, _ y: Double) -> Double { x - floor(x / y) * y }
    public static func spring(_ t: Double, response: Double, damping: Double) -> Double {
        let w = 2 * Double.pi / response
        let wd = w * sqrt(1 - damping * damping)
        return 1 - exp(-damping * w * t) * (cos(wd * t) + damping * w / wd * sin(wd * t))
    }
    public static func cubic(_ c: Curve, _ t: Double) -> CGPoint {
        let a = 1 - t
        return add(
            add(add(add(.zero, c[0], a * a * a), c[1], 3 * a * a * t), c[2], 3 * a * t * t), c[3],
            t * t * t)
    }
    public static func tangent(_ c: Curve, _ t: Double) -> CGPoint {
        let a = 1 - t
        return add(
            add(add(.zero, add(c[1], c[0], -1), 3 * a * a), add(c[2], c[1], -1), 6 * a * t),
            add(c[3], c[2], -1), 3 * t * t)
    }
    public static func reach(_ bounds: CGRect, _ p: CGPoint, _ v: CGPoint, _ length: Double)
        -> CGPoint
    {
        var n = length
        if v.x != 0 { n = min(n, ((v.x < 0 ? bounds.minX : bounds.maxX) - p.x) / v.x) }
        if v.y != 0 { n = min(n, ((v.y < 0 ? bounds.minY : bounds.maxY) - p.y) / v.y) }
        return add(p, v, max(0, n))
    }
    public static func candidates(_ start: CGPoint, _ end: CGPoint, bounds: CGRect) -> [[Curve]] {
        let d = distance(start, end)
        let along = toward(start, end)
        let hs = max(48, min(640, d * startHandle, d * 0.9))
        let he = max(48, min(640, d * endHandle, d * 0.9))
        func handles(_ k: Double) -> (CGPoint, CGPoint) {
            (reach(bounds, start, u, hs * k), reach(bounds, end, add(.zero, u, -1), he * k))
        }
        var paths: [[Curve]] = [1.0, 0.65].map {
            let h = handles($0)
            return [[start, h.0, h.1, end]]
        }
        let (leave, land) = handles(1)
        let normal = CGPoint(x: -along.y, y: along.x)
        let middle = add(
            add(start, end).applying(CGAffineTransform(scaleX: 0.5, y: 0.5)), u, hs * 0.16)
        let bow = clamp(d * arcSize, 50, 520)
        let flow = clamp(d * arcFlow, 38, 440)
        for s in [0.55, 0.8, 1.05] {
            for f in [0.65, 1.0, 1.35] {
                for side in [1.0, -1.0] {
                    let arc = add(middle, normal, side * bow * s)
                    paths.append([
                        [start, leave, add(arc, along, -flow * f), arc],
                        [arc, add(arc, along, flow * f), land, end],
                    ])
                }
            }
        }
        return paths
    }
    public static func measure(_ path: [Curve], bounds: CGRect) -> (
        length: Double, energy: Double, sharpest: Double, turn: Double, inside: Bool
    ) {
        var length = 0.0
        var energy = 0.0
        var sharpest = 0.0
        var turn = 0.0
        var inside = true
        var prev = path[0][0]
        var last: Double?
        for curve in path {
            for k in 0...samples {
                let q = cubic(curve, Double(k) / Double(samples))
                let step = distance(prev, q)
                length += step
                inside =
                    inside && q.x >= bounds.minX + margin && q.x <= bounds.maxX - margin
                    && q.y >= bounds.minY + margin && q.y <= bounds.maxY - margin
                if step > 0.01 {
                    let angle = atan2(q.y - prev.y, q.x - prev.x)
                    if let last {
                        let change = abs(
                            modulo(angle - last + Double.pi, 2 * Double.pi) - Double.pi)
                        energy += change * change
                        sharpest = max(sharpest, change)
                        turn += change
                    }
                    last = angle
                }
                prev = q
            }
        }
        return (length, energy, sharpest, turn, inside)
    }
    public static func glide(_ start: CGPoint, _ end: CGPoint, bounds: CGRect) -> (
        path: [Curve], response: Double
    ) {
        let d = distance(start, end)
        let alongU = ((end.x - start.x) * u.x + (end.y - start.y) * u.y) / d
        let against = clamp((-0.08 - alongU) / 0.92)
        var best: [Curve] = []
        var bestScore = Double.infinity
        var bestInside = false
        var response = 0.0
        for path in candidates(start, end, bounds: bounds) {
            let m = measure(path, bounds: bounds)
            let excess = max(m.length / d - 1, 0)
            let arc = path.count == 2 ? 1.0 : 0
            let bends = 140 * m.energy + 180 * m.sharpest + 18 * m.turn
            let score = m.length + 320 * excess + bends + 90 * against + 45 * arc
            let shape = clamp(
                0.42 * clamp(excess / 0.55) + 0.38 * clamp(m.turn / (1.4 * Double.pi)) + 0.2
                    * clamp(m.energy / 1.25))
            let total =
                0.42 + 0.22 * clamp((m.length - 180) / 760) + 0.12 * shape + 0.28 * against + 0.04
                * arc
            // A path that stays inside the bounds beats any that does not.
            if (m.inside && !bestInside) || (m.inside == bestInside && score < bestScore) {
                best = path
                bestScore = score
                bestInside = m.inside
                response = scaler * total * (arc == 1 ? 0.9 : 1)
            }
        }
        return (best, clamp(response, responseMin, responseMax))
    }
    public static func plan(_ start: CGPoint, _ end: CGPoint, bounds: CGRect) -> Move {
        var move = Move(start: end, end: end)
        let d = distance(start, end)
        if d < still { return move }
        move.mode = "hop"
        move.start = start
        move.response = hopResponse
        move.damping = hopDamping
        if d > hopMax {
            let g = glide(start, end, bounds: bounds)
            move.mode = "glide"
            move.path = g.path
            move.response = g.response
            move.damping = glideDamping
        }
        move.duration = tailTime * move.response
        var t = 0.0
        while t < move.duration
            && !(spring(t, response: move.response, damping: move.damping) >= 0.995
                && distance(position(move, t).point, end) <= 3.157)
        { t += 0.001 }
        move.arrive = t
        return move
    }
    public static func position(_ move: Move, _ t: Double) -> (point: CGPoint, heading: CGPoint) {
        if t >= move.duration { return (move.end, .zero) }
        let p = spring(t, response: move.response, damping: move.damping)
        if move.mode == "hop" { return (add(move.start, add(move.end, move.start, -1), p), .zero) }
        let q = clamp(p) * Double(move.path.count)
        let i = min(Int(q), move.path.count - 1)
        return (cubic(move.path[i], q - Double(i)), tangent(move.path[i], q - Double(i)))
    }
    public static func pose(_ move: Move, _ t: Double) -> (point: CGPoint, shape: Shape) {
        let (point, heading) = position(move, t)
        if t >= move.duration { return (point, rest) }
        if move.mode == "hop" {
            let v = toward(move.start, move.end)
            let p = clamp(spring(t, response: move.response, damping: move.damping))
            let e = min(1, p / 0.22) * pow(1 - p, 0.62)
            var axis = atan2(v.y, v.x) * 180 / Double.pi
            axis = axis > 90 ? axis - 180 : axis < -90 ? axis + 180 : axis
            let tilt = clamp(0.75 * v.x - 0.62 * v.y, -1, 1) * tiltMax * e
            return (point, Shape(a: axis, sx: 1 + stretch * e, sy: 1 - squash * e, b: tilt - axis))
        }
        var turn = 0.0
        if hypot(heading.x, heading.y) >= 0.001 {
            turn = modulo(atan2(heading.y, heading.x) * 180 / Double.pi - uAngle + 180, 360) - 180
        }
        let t0 = max(t - frame / 2, 0)
        let t1 = t + frame / 2
        let speed = distance(position(move, t0).point, position(move, t1).point) / (t1 - t0)
        return (
            point,
            Shape(
                a: turn + uAngle, sx: 1, sy: 1 / (1 + thinMax * clamp(speed / thinSpeed)),
                b: -uAngle)
        )
    }
}
