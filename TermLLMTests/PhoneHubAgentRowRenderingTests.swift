import SwiftUI
import XCTest
@testable import TermLLM

/// Lays out an agent page row in a real window and measures what it draws.
@MainActor
final class PhoneHubAgentRowRenderingTests: XCTestCase {
    private let now = Date()

    /// A spinner's text baseline is its top edge: aligned like text, it hung
    /// below the title line and pushed the caption down.
    func testRunningSpinnerIsCentredOnTheTimeAtEveryTextSize() async throws {
        let running = PhoneHubAgentConversation(id: "run", title: "Visible thinking web UI mockup",
                                                lastActivity: now, unseen: true, running: true)
        var waiting = running
        waiting.needsInput = true // The same two lines, without a spinner.
        for size in [DynamicTypeSize.xSmall, .large, .accessibility3] {
            XCTAssertEqual(height(running, size), height(waiting, size), accuracy: 0.5,
                           "\(size): the spinner stays inside the title line")

            let host = UIHostingController(rootView: row(running, size).frame(maxHeight: .infinity, alignment: .top))
            host.overrideUserInterfaceStyle = .light
            let window = try show(host)
            defer { window.isHidden = true }
            var spinner: UIActivityIndicatorView?
            for _ in 0..<100 where spinner == nil {
                try await Task.sleep(for: .milliseconds(20))
                spinner = Self.activityIndicator(in: host.view)
            }
            let indicator = try XCTUnwrap(spinner, "\(size): running rows show a spinner")
            let frame = indicator.convert(indicator.bounds, to: host.view)
            // Right of the spinner, the first thing drawn is the time.
            let time = try XCTUnwrap(Self.firstInkBand(host.view, rightOf: frame.maxX + 1), "\(size): the time is drawn")
            XCTAssertEqual(frame.midY, (time.lowerBound + time.upperBound) / 2, accuracy: 1,
                           "\(size): the spinner is centred on the time beside it")
        }
    }

    private func row(_ conversation: PhoneHubAgentConversation, _ size: DynamicTypeSize) -> some View {
        PhoneHubAgentConversationRow(conversation: conversation, now: now)
            .padding(.horizontal, 20)
            .background(Color.white)
            .environment(\.dynamicTypeSize, size)
    }

    private func height(_ conversation: PhoneHubAgentConversation, _ size: DynamicTypeSize) -> CGFloat {
        UIHostingController(rootView: row(conversation, size)).sizeThatFits(in: CGSize(width: 402, height: 1_000)).height
    }

    private func show(_ host: UIViewController) throws -> UIWindow {
        // Windows only draw when attached to a scene; borrow the test host's.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 300)
        window.backgroundColor = .white
        window.rootViewController = host
        window.makeKeyAndVisible()
        return window
    }

    private static func activityIndicator(in view: UIView) -> UIActivityIndicatorView? {
        if let indicator = view as? UIActivityIndicatorView { return indicator }
        return view.subviews.lazy.compactMap(activityIndicator(in:)).first
    }

    /// Top and bottom, in points, of the first unbroken band of non-white
    /// pixels right of `minX`.
    private static func firstInkBand(_ view: UIView, rightOf minX: CGFloat) -> ClosedRange<CGFloat>? {
        let format = UIGraphicsImageRendererFormat()
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let scale = CGFloat(width) / view.bounds.width
        let columns = min(width, Int((minX * scale).rounded(.up)))..<width
        var band: ClosedRange<Int>?
        for y in 0..<height {
            let inked = columns.contains { x in
                let pixel = (y * width + x) * 4
                return min(pixels[pixel], pixels[pixel + 1], pixels[pixel + 2]) < 200
            }
            if inked {
                band = (band?.lowerBound ?? y)...y
            } else if band != nil {
                break
            }
        }
        return band.map { CGFloat($0.lowerBound) / scale...CGFloat($0.upperBound + 1) / scale }
    }
}

@MainActor
final class WorkspaceChromeTests: XCTestCase {
    func testQuietHeaderUsesOne52PointRowAtDefaultTextSize() {
        let header = WorkspaceHeader(title: "Agents", subtitle: "All connections", onToggleSidebar: {}) {
            Button {} label: { Image(systemName: "arrow.clockwise").frame(width: 32, height: 44) }
        }
        .environment(\.dynamicTypeSize, .large)
        let host = UIHostingController(rootView: header)
        for width: CGFloat in [568, 900, 1220] {
            let size = host.sizeThatFits(in: CGSize(width: width, height: 500))
            XCTAssertEqual(size.height, 52, accuracy: 0.5, "No oversized title/capsule chrome at \(width)pt")
            XCTAssertLessThanOrEqual(size.width, width)
        }
    }

    func testQuietHeaderAllowsAccessibilityTextToGrowRatherThanClip() {
        let host = UIHostingController(rootView: WorkspaceHeader(title: "Agents") { EmptyView() }
            .environment(\.dynamicTypeSize, .accessibility5))
        XCTAssertGreaterThan(host.sizeThatFits(in: CGSize(width: 568, height: 500)).height, 52)
    }

    func testPhoneHomeDefaultsToExistingSystemNavigationChrome() {
        let view = PhoneHubView(connections: HubConnectionStore(defaults: isolatedDefaults()),
                                aggregate: HubAggregateStore(), pendingConnectionURL: .constant(nil),
                                isVisible: true, onOpenChat: { _, _ in }, onSettings: {})
        XCTAssertFalse(view.usesWorkspaceChrome)
        XCTAssertNil(view.onToggleSidebar)
    }
}
