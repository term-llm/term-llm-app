import XCTest

@testable import ComputerUseCore

final class OverlayStateTests: XCTestCase {
    let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)],
        button = CGRect(x: 100, y: 60, width: 40, height: 20)
    func shown(_ p: CGPoint = CGPoint(x: 700, y: 400)) -> PointerTrack {
        let t = PointerTrack(now: 0)
        t.go(p, now: 0, screens: screens)
        return t
    }
    func testFirstShow() {
        let t = shown()
        for (time, opacity, blur) in [(0.0, 0.0, 7.0), (0.22, 0.5, 3.5), (0.44, 1.0, 0.0)] {
            let f = t.frame(time)!
            XCTAssertEqual(f.point, CGPoint(x: 700, y: 400))
            XCTAssertEqual(f.shape, Pointer.rest)
            XCTAssertEqual(f.opacity, opacity)
            XCTAssertEqual(f.blur, blur)
        }
        XCTAssertEqual(t.frame(0)!.wake, 0)
        XCTAssertEqual(t.frame(0.44)!.wake, 29.56, accuracy: 1e-9)
    }
    func testSameTargetAndRetarget() {
        let t = shown(CGPoint(x: 100, y: 100))
        t.go(CGPoint(x: 900, y: 600), now: 10, screens: screens)
        let running = t.move!
        t.go(CGPoint(x: 900.3, y: 600), now: 10.1, screens: screens)
        XCTAssertEqual(t.began, 10)
        t.go(CGPoint(x: 300, y: 200), now: 10.12, screens: screens)
        XCTAssertEqual(t.move!.start.x, Pointer.pose(running, 0.12).point.x, accuracy: 1e-8)
        XCTAssertEqual(t.began, 10.12)
        let pose = Pointer.pose(t.move!, 0)
        XCTAssertEqual(pose.shape.a + pose.shape.b, 0, accuracy: 1e-8)
        XCTAssertEqual(pose.shape.sx, 1)
    }
    func testChainOfTenActions() {
        let t = PointerTrack(now: 0)
        for i in 0..<10 {
            t.go(
                CGPoint(x: 100 + 97 * i, y: 100 + 53 * (i % 3)), now: Double(i) * 0.05,
                screens: screens)
            t.press(1, now: Double(i) * 0.05)
        }
        let f = t.frame(3)!
        XCTAssertEqual(f.point, CGPoint(x: 973, y: 100))
        XCTAssertEqual(f.shape, Pointer.rest)
        XCTAssertEqual(f.press, 1)
        XCTAssertEqual(f.opacity, 1)
        XCTAssertGreaterThan(f.wake, 0)
    }
    func testJumpAndOutsideScreens() {
        let t = shown()
        t.go(CGPoint(x: 900, y: 600), now: 5, screens: screens, animate: false)
        XCTAssertEqual(t.frame(5)!.point, CGPoint(x: 900, y: 600))
        XCTAssertEqual(t.frame(5)!.shape, Pointer.rest)
        t.go(CGPoint(x: 1600, y: -40), now: 6, screens: screens)
        XCTAssertEqual(t.move!.end, CGPoint(x: 1440, y: 0))
        XCTAssertEqual(shown(CGPoint(x: -50, y: 2000)).frame(0)!.point, CGPoint(x: 0, y: 900))
    }
    func testPressWaitsForArrivalAndPulsesTwice() {
        let t = shown(CGPoint(x: 100, y: 100))
        t.go(CGPoint(x: 900, y: 600), now: 1, screens: screens)
        t.press(2, now: 1)
        let arrival = 1 + t.move!.arrive
        XCTAssertEqual(t.frame(arrival - 0.01)!.press, 1)
        let first = t.frame(arrival + 0.075)!.press
        let between = t.frame(arrival + 0.125)!.press
        let second = t.frame(arrival + 0.175)!.press
        XCTAssertLessThan(first, 0.9)
        XCTAssertLessThan(second, 0.9)
        XCTAssertGreaterThan(between, max(first, second))
        XCTAssertEqual(t.frame(arrival + 0.5)!.press, 1)
    }
    func testFirstPressWaitsForFadeAndRetargetDropsPendingPulse() {
        let t = shown()
        t.press(1, now: 0)
        let deepest = (0..<1000).map { t.frame(Double($0) / 1000)! }.min { $0.press < $1.press }!
        XCTAssertLessThan(deepest.press, 0.9)
        XCTAssertEqual(deepest.opacity, 1)
        t.go(CGPoint(x: 100, y: 100), now: 1, screens: screens)
        t.press(1, now: 1)
        t.go(CGPoint(x: 300, y: 300), now: 1.05, screens: screens)
        for ms in 0..<1500 { XCTAssertEqual(t.frame(1.05 + Double(ms) / 1000)!.press, 1) }
    }
    func testIdleFadeAndRevival() {
        let t = shown()
        XCTAssertEqual(t.frame(29.99)!.opacity, 1)
        XCTAssertEqual(t.frame(30.22)!.opacity, 0.5, accuracy: 1e-9)
        XCTAssertNil(t.frame(30.44))
        XCTAssertNil(PointerTrack(now: 0).frame(30.44))
        t.go(CGPoint(x: 900, y: 600), now: 30.3, screens: screens)
        XCTAssertEqual(t.frame(30.3)!.opacity, 1)
        XCTAssertEqual(t.move!.start, CGPoint(x: 700, y: 400))
        XCTAssertNotNil(t.frame(30.54))
    }
    func testPausedLoadingAndIdle() {
        let t = shown()
        t.act("paused", now: 1)
        XCTAssertEqual(t.frame(1)!.opacity, 0.5)
        t.act("loading", now: 2)
        t.act("loading", now: 2.3)
        for (offset, angle) in [(0.0, 0.0), (0.685 / 2, 10.0), (0.685, 0.0), (0.685 * 1.5, -10.0)] {
            let f = t.frame(2 + offset)!
            XCTAssertEqual(f.shape.a, angle, accuracy: 1e-8)
            XCTAssertEqual(f.fill, 0.24)
            XCTAssertEqual(f.point, CGPoint(x: 700, y: 400))
        }
        XCTAssertEqual(t.frame(2.4)!.wake, 1.0 / 30)
        t.act("idle", now: 5)
        XCTAssertEqual(t.frame(5)!.shape, Pointer.rest)
        XCTAssertEqual(t.frame(5)!.fill, Pointer.fill)
    }
    func testLoadingGlidesBeforeRocking() {
        let t = shown(CGPoint(x: 100, y: 100))
        t.act("loading", now: 1)
        t.go(CGPoint(x: 900, y: 600), now: 3, screens: screens)
        let arrive = 3 + t.move!.duration
        XCTAssertEqual(t.frame(3.1)!.shape.a, Pointer.pose(t.move!, 0.1).shape.a, accuracy: 1e-8)
        XCTAssertEqual(t.frame(arrive)!.shape, Pointer.rest)
        XCTAssertEqual(t.frame(arrive + 0.685 / 2)!.shape.a, 10, accuracy: 1e-8)
    }
    func testFlashWaitsForPulseAndFades() {
        let s = OverlayScene(now: 0)
        s.command(.move(CGPoint(x: 110, y: 65)), now: 0, screens: screens)
        s.command(.flash(button), now: 10, screens: screens)
        for (offset, alpha) in [(0.0, 1.0), (0.3, 1.0), (0.52, 0.5), (0.74, 0.0)] {
            XCTAssertEqual(s.flash.alpha(10 + offset), alpha, accuracy: 1e-8)
        }
        s.command(.move(CGPoint(x: 260, y: 65)), now: 20, screens: screens)
        s.command(.flash(CGRect(x: 250, y: 60, width: 40, height: 20)), now: 20, screens: screens)
        XCTAssertEqual(s.flash.until, 20.473, accuracy: 0.002)
        XCTAssertGreaterThan(s.flash.alpha(20.9), 0)
        XCTAssertEqual(s.flash.alpha(20.92), 0)
    }
    func testFirstFlashAndCentreFallback() {
        let s = OverlayScene(now: 0)
        s.command(.flash(button, pid: 42, window: 7), now: 0, screens: screens)
        XCTAssertEqual(s.track.move!.end, CGPoint(x: 120, y: 70))
        XCTAssertEqual(s.pid, 42)
        XCTAssertEqual(s.window, 7)
        XCTAssertEqual(s.flash.alpha(0), 1)
        XCTAssertEqual(s.flash.until, 0.74)
        s.command(.move(CGPoint(x: 110, y: 65)), now: 1, screens: screens)
        s.command(.flash(button), now: 1, screens: screens)
        XCTAssertEqual(s.track.move!.end, CGPoint(x: 110, y: 65))
        s.command(.flash(CGRect(x: 500, y: 500, width: 10, height: 10)), now: 2, screens: screens)
        s.command(
            .flash(CGRect(x: 0, y: 0, width: 700, height: 500)), now: 3, screens: screens,
            calm: true)
        XCTAssertEqual(s.track.frame(3)!.point, CGPoint(x: 350, y: 250))
    }
    func testFlashSizeRules() {
        for r in [
            CGRect(x: 1, y: 2, width: 0, height: 5), CGRect(x: 1, y: 2, width: 5, height: 0),
            CGRect(x: 1, y: 2, width: -5, height: -5),
        ] { XCTAssertNil(OverlayGeometry.flashBox(r, within: nil)) }
        let window = CGRect(x: 0, y: 0, width: 800, height: 600)
        let half = CGRect(x: 0, y: 0, width: 400, height: 600)
        XCTAssertNil(
            OverlayGeometry.flashBox(CGRect(x: 0, y: 0, width: 700, height: 500), within: window))
        XCTAssertEqual(OverlayGeometry.flashBox(half, within: window), half)
        XCTAssertNotNil(
            OverlayGeometry.flashBox(CGRect(x: 0, y: 0, width: 5000, height: 5000), within: nil))
        let s = OverlayScene(now: 0)
        s.command(.flash(button), now: 0, screens: screens)
        s.command(.flash(.zero), now: 0.1, screens: screens)
        XCTAssertEqual(s.flash.alpha(0.1), 0)
    }
    func testHaloLifecycle() {
        let s = OverlayScene(now: 0)
        let frame = CGRect(x: 100, y: 50, width: 800, height: 600)
        s.command(.halo(frame, pid: 42, window: 7), now: 0, screens: screens)
        for (t, a) in [
            (0.0, 0.0), (0.22, 0.5), (0.44, 1.0), (10.0, 1.0), (10.22, 0.5), (10.44, 0.0),
        ] {
            XCTAssertEqual(s.halo.alpha(t), a, accuracy: 1e-8)
        }
        s.command(.halo(frame), now: 8, screens: screens)
        XCTAssertEqual(s.halo.alpha(17.99), 1)
        XCTAssertEqual(s.halo.alpha(18.44), 0)
        s.command(.halo(frame), now: 18.3, screens: screens)
        XCTAssertEqual(s.halo.alpha(18.3), 1)
        s.command(.halo(frame), now: 60, screens: screens)
        XCTAssertEqual(s.halo.alpha(60), 0)
        XCTAssertEqual(s.halo.alpha(60.44), 1)
    }
    func testWakeScheduleAndEmptyMark() {
        let s = OverlayScene(now: 0)
        s.command(.halo(button), now: 0, screens: screens)
        XCTAssertEqual(s.wake(0.1, frame: s.track.frame(0.1)!), 0)
        XCTAssertEqual(s.wake(5, frame: s.track.frame(5)!), 0.1)
        XCTAssertEqual(s.wake(10.1, frame: s.track.frame(10.1)!), 0)
        XCTAssertEqual(s.wake(10.44, frame: s.track.frame(10.44)!), 20, accuracy: 1e-8)
        let mark = OverlayMark()
        XCTAssertEqual(mark.alpha(1), 0)
        XCTAssertFalse(mark.alive(1))
        XCTAssertEqual(mark.wake(1), .infinity)
    }
    func testTurnDoneIsIdempotentAndNextCommandRevives() {
        let s = OverlayScene(now: 0)
        s.command(.move(CGPoint(x: 110, y: 65)), now: 0, screens: screens)
        s.command(.halo(button), now: 0, screens: screens)
        s.command(.done, now: 5, screens: screens)
        s.command(.done, now: 5.5, screens: screens)
        XCTAssertEqual(s.halo.alpha(5), 1)
        XCTAssertEqual(s.halo.alpha(5.44), 0)
        XCTAssertEqual(s.track.frame(7.22)!.opacity, 0.5, accuracy: 1e-8)
        XCTAssertNil(s.track.frame(7.44))
        s.command(.move(CGPoint(x: 110, y: 65)), now: 6, screens: screens)
        XCTAssertEqual(s.track.frame(36)!.opacity, 1)
    }
    func testHaloFollowsWindowAndHidesOffSpace() {
        let m = OverlayMark()
        m.pid = 42
        m.window = 7
        m.show(button, now: 0, until: 10)
        let moved = OverlayGeometry.Window(
            id: 7, pid: 42, level: 3, bounds: CGRect(x: 300, y: 200, width: 600, height: 500))
        XCTAssertEqual(m.follow([moved], now: 0.1), .init(level: 3, window: 7))
        XCTAssertEqual(m.box, moved.bounds)
        XCTAssertNil(m.follow([], now: 0.2))
        XCTAssertEqual(m.box, moved.bounds)
        XCTAssertNil(m.follow([moved], now: 10.44))
        m.window = 0
        m.show(button, now: 20, until: 30)
        let under = OverlayGeometry.Window(
            id: 8, pid: 42, level: 0, bounds: CGRect(x: 90, y: 40, width: 820, height: 620))
        XCTAssertEqual(m.follow([under], now: 20.1), .init(level: 0, window: 8))
    }
    func testAnyCommandKeepsAlive() {
        let s = OverlayScene(now: 0)
        s.command(.move(.zero), now: 0, screens: screens)
        s.command(.activity("loading"), now: 25, screens: screens)
        s.command(.halo(button), now: 50, screens: screens)
        XCTAssertEqual(s.track.frame(80)!.opacity, 1)
        XCTAssertNil(s.track.frame(80.44))
    }
    func testNegativeScreenCoordinates() {
        let screens = OverlayGeometry.flipScreens([
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        ])
        XCTAssertEqual(screens[1], CGRect(x: -1920, y: -180, width: 1920, height: 1080))
        XCTAssertEqual(
            OverlayGeometry.bounds(of: screens, points: [CGPoint(x: -100, y: -100)]), screens[1])
        for points in [
            [CGPoint(x: -100, y: -100), CGPoint(x: 700, y: 400)], [CGPoint(x: 5000, y: 5000)],
        ] {
            XCTAssertEqual(
                OverlayGeometry.bounds(of: screens, points: points),
                CGRect(x: -1920, y: -180, width: 3360, height: 1080))
        }
        XCTAssertEqual(
            OverlayGeometry.windowOrigin(CGPoint(x: -100, y: -100), primaryHeight: 900),
            CGPoint(x: -156, y: 944))
        let box = OverlayGeometry.grow(CGRect(x: 100, y: 50, width: 800, height: 600), by: 3)
        XCTAssertEqual(box, CGRect(x: 97, y: 47, width: 806, height: 606))
        XCTAssertEqual(
            OverlayGeometry.windowFrame(box, primaryHeight: 900),
            CGRect(x: 97, y: 247, width: 806, height: 606))
    }
    func testStackingAndTargetLookup() {
        let windows = [
            OverlayGeometry.Window(
                id: 7, pid: 99, level: 0, bounds: CGRect(x: 0, y: 0, width: 500, height: 500)),
            .init(
                id: 8, pid: 42, level: 0, bounds: CGRect(x: 100, y: 100, width: 300, height: 300)),
            .init(id: 9, pid: 42, level: 3, bounds: CGRect(x: 0, y: 0, width: 1000, height: 800)),
        ]
        let p = CGPoint(x: 200, y: 200)
        XCTAssertEqual(
            OverlayGeometry.stacking(p, pid: nil, frontmost: 1, windows: windows),
            .init(level: 102, window: 0))
        XCTAssertEqual(
            OverlayGeometry.stacking(p, pid: 42, frontmost: 42, windows: windows),
            .init(level: 102, window: 0))
        XCTAssertEqual(
            OverlayGeometry.stacking(p, pid: 42, frontmost: 1, windows: windows),
            .init(level: 0, window: 8))
        XCTAssertEqual(
            OverlayGeometry.stacking(
                CGPoint(x: 600, y: 600), pid: 42, frontmost: 1, windows: windows),
            .init(level: 3, window: 9))
        XCTAssertNil(
            OverlayGeometry.stacking(
                CGPoint(x: 2000, y: 600), pid: 42, frontmost: 1, windows: windows))
        XCTAssertEqual(
            OverlayGeometry.targetWindow(p, pid: 42, windows: windows, window: 9), windows[2])
        XCTAssertNil(OverlayGeometry.targetWindow(p, pid: 42, windows: windows, window: 77))
        XCTAssertNil(OverlayGeometry.targetWindow(p, pid: nil, windows: windows))
    }
    func testInvalidCommandsAreIgnored() {
        let s = OverlayScene(now: 0)
        for command in [
            OverlayCommand.move(CGPoint(x: Double.nan, y: 1)), .activity("other"), .press(-1),
            .halo(CGRect(x: 0, y: 0, width: Double.infinity, height: 1)),
        ] {
            XCTAssertFalse(command.valid)
            s.command(command, now: 1, screens: screens)
        }
        XCTAssertNil(s.track.move)
        XCTAssertNil(s.halo.box)
    }
}
