import XCTest

@testable import ComputerUseCore

final class PointerTests: XCTestCase {
    func testOutline() {
        let p = Pointer.outlinePoints()
        let xs = p.map(\.x)
        let ys = p.map(\.y)
        XCTAssertEqual(p.count, 22)
        XCTAssertEqual(p[0].x, -4, accuracy: 0.01)
        XCTAssertEqual(p[0].y, -1.97, accuracy: 0.01)
        XCTAssertTrue(p.contains(Pointer.notch))
        XCTAssertEqual(xs.max()! - xs.min()!, 13, accuracy: 0.1)
        XCTAssertEqual(ys.max()! - ys.min()!, 13.4, accuracy: 0.1)
        XCTAssertLessThan(xs.min()!, 0)
        XCTAssertGreaterThan(xs.max()!, 0)
        XCTAssertLessThan(ys.min()!, 0)
        XCTAssertGreaterThan(ys.max()!, 0)
    }
    func testSharedMotionFixture() throws {
        let file = try XCTUnwrap(
            Bundle.module.url(
                forResource: "pointer-motion", withExtension: "json",
                subdirectory: "Fixtures/pointer"))
        let fixture = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        let tolerance = try XCTUnwrap(fixture["tolerance"] as? [String: Double])
        for c in cases {
            let start = c["start"] as! [Double]
            let end = c["end"] as! [Double]
            let b = c["bounds"] as! [Double]
            let name = c["name"] as! String
            let move = Pointer.plan(
                CGPoint(x: start[0], y: start[1]), CGPoint(x: end[0], y: end[1]),
                bounds: CGRect(x: b[0], y: b[1], width: b[2] - b[0], height: b[3] - b[1]))
            XCTAssertEqual(move.mode, c["mode"] as! String, name)
            XCTAssertEqual(move.path.count, c["parts"] as! Int, name)
            XCTAssertEqual(
                move.duration, c["duration"] as! Double, accuracy: tolerance["time"]!, name)
            XCTAssertEqual(move.arrive, c["arrive"] as! Double, accuracy: tolerance["time"]!, name)
            let steps = max(1, Int(ceil(move.duration / Pointer.frame)))
            let frames = c["frames"] as! [[Double]]
            XCTAssertEqual(frames.count, steps + 1, name)
            for (i, want) in frames.enumerated() {
                let p = Pointer.pose(move, move.duration * Double(i) / Double(steps))
                let got = [p.point.x, p.point.y, p.shape.a, p.shape.sx, p.shape.sy, p.shape.b]
                for j in [0, 1] {
                    XCTAssertEqual(
                        got[j], want[j], accuracy: tolerance["position"]!, "\(name) frame \(i)")
                }
                for j in [3, 4] {
                    XCTAssertEqual(got[j], want[j], accuracy: tolerance["scale"]!, name)
                }
                // At rest R(-134) × identity × R(134) and R(0) are the
                // same pose. Python/Swift differ by an ulp at the final sample.
                if abs(got[3] - 1) < 1e-10 && abs(got[4] - 1) < 1e-10 && want[3] == 1
                    && want[4] == 1
                {
                    XCTAssertLessThanOrEqual(
                        abs(Pointer.modulo(got[2] + got[5] - want[2] - want[5] + 180, 360) - 180),
                        tolerance["angle"]!, name)
                } else {
                    for j in [2, 5] {
                        XCTAssertLessThanOrEqual(
                            abs(Pointer.modulo(got[j] - want[j] + 180, 360) - 180),
                            tolerance["angle"]!, name)
                    }
                }
            }
            if ["along the top edge", "out of the top left corner", "into the bottom right corner"]
                .contains(name)
            {
                for ms in stride(from: 0, through: Int((move.duration * 1000).rounded()), by: 4) {
                    let p = Pointer.pose(move, Double(ms) / 1000).point
                    XCTAssertGreaterThanOrEqual(p.x, b[0] - 2)
                    XCTAssertLessThanOrEqual(p.x, b[2] + 2)
                    XCTAssertGreaterThanOrEqual(p.y, b[1] - 2)
                    XCTAssertLessThanOrEqual(p.y, b[3] + 2)
                }
                XCTAssertEqual(Pointer.pose(move, move.duration).shape, Pointer.rest)
            }
        }
    }
    func testDistanceModes() {
        let b = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let p = CGPoint(x: 100, y: 100)
        XCTAssertEqual(Pointer.plan(p, CGPoint(x: 100.3, y: 100), bounds: b).mode, "still")
        let hop = Pointer.plan(p, CGPoint(x: 296, y: 100), bounds: b)
        XCTAssertEqual(hop.mode, "hop")
        XCTAssertEqual(hop.arrive, 0.173, accuracy: 0.0001)
        XCTAssertEqual(Pointer.plan(p, CGPoint(x: 297, y: 100), bounds: b).mode, "glide")
    }
    func testPressPulse() {
        for t in [-1.0, 0, 0.3, 9] { XCTAssertEqual(Pointer.pressScale(t), 1) }
        let lowest = (0..<300).min {
            Pointer.pressScale(Double($0) / 1000) < Pointer.pressScale(Double($1) / 1000)
        }!
        XCTAssertEqual(lowest, 75)
        XCTAssertEqual(Pointer.pressScale(0.075), 0.881)
    }
}
