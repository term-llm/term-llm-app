import XCTest
import SwiftUI
import UIKit
import WebKit
@testable import TermLLM

final class ResponsivenessDiagnosticsTests: XCTestCase {
    @MainActor
    func testDiagnosticsScreenIsNativeWithoutBrowserOrServer() {
        let host = UIHostingController(rootView: NavigationStack { FlightDiagnosticsView() })
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        host.view.layoutIfNeeded()
        func containsBrowser(_ view: UIView) -> Bool {
            view is WKWebView || view.subviews.contains(where: containsBrowser)
        }
        XCTAssertFalse(containsBrowser(host.view))
    }

    func testNativeStallIsReportedOnceAndRecoveryMeasuresOutstandingPing() {
        var native = ResponsivenessState(threshold: 5, grace: 3)
        native.setActive(true, now: 0)
        XCTAssertNil(native.begin(now: 2))
        let ping = native.begin(now: 3)!
        XCTAssertNil(native.tick(now: 7.9))
        XCTAssertEqual(native.tick(now: 8), .stalled)
        XCTAssertNil(native.tick(now: 20))
        XCTAssertNil(native.begin(now: 20), "Do not accumulate main queue pings")
        XCTAssertEqual(native.complete(ping, now: 21), .recovered(18))
        XCTAssertNil(native.complete(ping, now: 22))
        XCTAssertNotNil(native.begin(now: 22))
    }

    func testPageStallDoesNotRequireNativeStallAndKeepsSingleTransportSlot() {
        var native = ResponsivenessState(threshold: 5, grace: 0)
        var page = ResponsivenessState(threshold: 5, grace: 0)
        native.setActive(true, now: 0)
        page.setActive(true, now: 0)
        let pageProbe = page.begin(now: 0)!
        for time in 0..<20 {
            let ping = native.begin(now: Double(time))!
            XCTAssertNil(native.complete(ping, now: Double(time) + 0.1))
            XCTAssertNil(page.begin(now: Double(time)))
        }
        XCTAssertNil(native.tick(now: 20))
        XCTAssertEqual(page.tick(now: 20), .stalled)
        XCTAssertNil(page.begin(now: 1000), "A JS timeout is not cancellation")
        XCTAssertEqual(page.complete(pageProbe, now: 1001), .recovered(1001))
    }

    func testInactiveAndBackgroundTimeAreNotChargedToOutstandingProbe() {
        var state = ResponsivenessState(threshold: 5, grace: 3)
        state.setActive(true, now: 0)
        let probe = state.begin(now: 3)!
        state.setActive(false, now: 4)
        XCTAssertNil(state.tick(now: 500))
        XCTAssertNil(state.begin(now: 500))
        state.setActive(true, now: 600)
        XCTAssertNil(state.tick(now: 607.9))
        XCTAssertEqual(state.tick(now: 608), .stalled)
        XCTAssertEqual(state.complete(probe, now: 610), .recovered(7))
    }

    func testSuspectedStallIsDiscardedOnResignActiveNotRecoveredAsLongStall() {
        var state = ResponsivenessState(threshold: 5, grace: 0)
        state.setActive(true, now: 0)
        let probe = state.begin(now: 0)!
        XCTAssertEqual(state.tick(now: 5), .stalled)
        state.setActive(false, now: 6)
        XCTAssertNil(state.complete(probe, now: 100))
        state.setActive(true, now: 101)
        XCTAssertNil(state.tick(now: 200))
    }

    func testNavigationInvalidatesEvidenceButDoesNotEnqueueBehindOldEvaluation() {
        var page = ResponsivenessState(threshold: 5, grace: 3)
        page.setActive(true, now: 0)
        let old = page.begin(now: 3)!
        XCTAssertEqual(page.tick(now: 8), .stalled)
        page.navigate(now: 9)
        XCTAssertNotEqual(page.document, old.document)
        XCTAssertNil(page.tick(now: 100))
        XCTAssertNil(page.begin(now: 100))
        XCTAssertNil(page.complete(old, now: 101), "Old document cannot report recovery for new document")
        let current = page.begin(now: 102)!
        XCTAssertNil(page.complete(old, now: 103), "Duplicate stale callback cannot release current slot")
        XCTAssertEqual(page.pending, current)
        XCTAssertEqual(page.tick(now: 107), .stalled)
        XCTAssertEqual(page.complete(current, now: 108), .recovered(6))
    }

    func testFreshDocumentGetsNavigationGrace() {
        var page = ResponsivenessState(threshold: 5, grace: 3)
        page.setActive(true, now: 0)
        let old = page.begin(now: 3)!
        XCTAssertNil(page.complete(old, now: 4))
        page.navigate(now: 5)
        XCTAssertNil(page.begin(now: 7))
        let current = page.begin(now: 8)!
        XCTAssertEqual(current.document, page.document)
        XCTAssertNil(page.tick(now: 12))
        XCTAssertEqual(page.tick(now: 13), .stalled)
    }

    func testTimerDiscontinuityGetsFreshGraceWithoutLosingSlot() {
        var state = ResponsivenessState(threshold: 5, grace: 3)
        state.setActive(true, now: 0)
        let probe = state.begin(now: 3)!
        state.resetGrace(now: 1000)
        XCTAssertNil(state.tick(now: 1007))
        XCTAssertNil(state.begin(now: 1007))
        XCTAssertEqual(state.tick(now: 1008), .stalled)
        XCTAssertEqual(state.complete(probe, now: 1009), .recovered(6))
    }

    func testRepeatedForegroundUpdatesDoNotExtendGraceOrClearStall() {
        var state = ResponsivenessState(threshold: 5, grace: 3)
        state.setActive(true, now: 0)
        state.setActive(true, now: 2)
        let probe = state.begin(now: 3)!
        state.setActive(true, now: 7)
        XCTAssertEqual(state.tick(now: 8), .stalled)
        state.setActive(true, now: 9)
        XCTAssertEqual(state.complete(probe, now: 10), .recovered(7))
    }

    func testInactiveNavigationDoesNotActivateMonitoring() {
        var state = ResponsivenessState()
        state.navigate(now: 10)
        XCTAssertNil(state.begin(now: 100))
        XCTAssertNil(state.tick(now: 100))
        state.setActive(true, now: 101)
        XCTAssertNil(state.begin(now: 103))
        XCTAssertNotNil(state.begin(now: 104))
    }
}
