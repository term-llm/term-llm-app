import ComputerUseCore
import Foundation
import ImageIO
import XCTest
@testable import ComputerUseSystem

final class ScreenshotTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws { folder = try temporaryFolder() }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    private func screenshot(sources: [Screenshot.Source] = [{ _, _ in fakeImage() }]) -> Screenshot {
        Screenshot(folder: folder.appendingPathComponent("shots"), stateDirectory: { self.folder.appendingPathComponent("state") }, sources: sources, appName: { _ in "Font Book" })
    }
    func testCaptureJPEGAndMapping() throws {
        let shot = try screenshot().capture(fixtureWindow())
        XCTAssertEqual(URL(fileURLWithPath: shot.path).deletingLastPathComponent(), folder.appendingPathComponent("shots"))
        XCTAssertNotNil(URL(fileURLWithPath: shot.path).lastPathComponent.range(of: "^Font Book Screenshot \\d{4}-\\d\\d-\\d\\d at \\d{1,2}\\.\\d\\d\\.\\d\\d [AP]M [a-z0-9]{6}\\.jpeg$", options: .regularExpression))
        XCTAssertEqual(shot.scale, 2); XCTAssertEqual(shot.origin, CGPoint(x: 60, y: 58)); XCTAssertEqual(shot.width, 64); XCTAssertEqual(shot.height, 48)
        XCTAssertEqual(shot.toScreen(x: 10, y: 20), CGPoint(x: 65, y: 68))
        let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: shot.path) as CFURL, nil)!
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        XCTAssertEqual(image.width, 64); XCTAssertEqual(image.height, 48); XCTAssertEqual(Screenshot.jpegQuality, 0.8)
    }
    func testJPEGUsesExactUpstreamQuality80QuantizationTables() throws {
        let path = folder.appendingPathComponent("quality.jpeg")
        try Screenshot.writeJPEG(fakeImage(), path: path)
        let bytes = Array(try Data(contentsOf: path))
        XCTAssertEqual(Array(bytes.prefix(2)), [0xff, 0xd8])
        let zigzag = [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63]
        var tables: [Int: [Int]] = [:], cursor = 2, baseline = false
        while cursor + 4 <= bytes.count {
            XCTAssertEqual(bytes[cursor], 0xff)
            let marker = bytes[cursor + 1]
            if marker == 0xda || marker == 0xd9 { break }
            let length = Int(bytes[cursor + 2]) * 256 + Int(bytes[cursor + 3])
            guard length >= 2, cursor + 2 + length <= bytes.count else { return XCTFail("Invalid JPEG segment") }
            let end = cursor + 2 + length
            if marker == 0xdb {
                var offset = cursor + 4
                while offset < end {
                    let info = Int(bytes[offset]); offset += 1
                    XCTAssertEqual(info >> 4, 0) // 8-bit quantization, as upstream.
                    guard offset + 64 <= end else { return XCTFail("Truncated table") }
                    var table = [Int](repeating: 0, count: 64)
                    for scan in 0..<64 { table[zigzag[scan]] = Int(bytes[offset + scan]) }
                    tables[info & 15] = table; offset += 64
                }
            }
            if marker == 0xc0 { baseline = true; XCTAssertEqual(bytes[cursor + 9], 3) } // Three RGB/YCC components, not progressive.
            cursor = end
        }
        XCTAssertTrue(baseline)
        let expected = [
            0: [2, 2, 2, 3, 4, 5, 7, 8, 2, 2, 2, 3, 4, 5, 7, 8, 2, 2, 3, 4, 5, 7, 8, 10, 3, 3, 4, 5, 7, 8, 10, 11, 4, 4, 5, 7, 8, 10, 11, 13, 5, 5, 7, 8, 10, 11, 13, 13, 7, 7, 8, 10, 11, 13, 13, 13, 8, 8, 10, 11, 13, 13, 13, 13],
            1: [2, 2, 3, 6, 13, 13, 13, 13, 2, 3, 3, 9, 13, 13, 13, 13, 3, 3, 7, 13, 13, 13, 13, 13, 6, 9, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13],
        ]
        XCTAssertEqual(tables, expected)
    }
    func testFileNamingAndRandomSuffix() {
        let formatter = ISO8601DateFormatter()
        let date = formatter.date(from: "2026-10-11T23:50:57Z")!
        let one = Screenshot.fileName("Safari", now: date, timeZone: TimeZone(secondsFromGMT: 0)!)
        let two = Screenshot.fileName("Safari", now: date, timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertTrue(one.hasPrefix("Safari Screenshot 2026-10-11 at 11.50.57 PM ")); XCTAssertNotEqual(one, two)
        XCTAssertEqual(one.components(separatedBy: " ").last!.count, 11)
        for (time, clock) in [("00:05:09", "12.05.09 AM"), ("09:05:09", "9.05.09 AM")] {
            XCTAssertTrue(Screenshot.fileName("A", now: formatter.date(from: "2026-01-02T\(time)Z")!, timeZone: TimeZone(secondsFromGMT: 0)!).contains(" at \(clock) "))
        }
    }
    func testKeptProofIsPrivateCappedAndOutsideHourlyCleanup() throws {
        let source = folder.appendingPathComponent("Text Edit Screenshot x7k2qd.jpeg")
        try Data("jpeg".utf8).write(to: source)
        let screenshot = screenshot()
        var paths: [String] = []
        for second in 0...Screenshot.proofMax {
            let path = try screenshot.keep(source.path, appName: "Text Edit", now: Date(timeIntervalSince1970: Double(1_790_000_000 + second)))
            // Force distinct mtime order, independent of filesystem timer resolution.
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(second))], ofItemAtPath: path)
            paths.append(path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths[0])); XCTAssertTrue(FileManager.default.fileExists(atPath: paths.last!))
        XCTAssertFalse(paths.last!.contains(" ")); XCTAssertTrue(paths.last!.hasSuffix("-x7k2qd.jpeg"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: paths.last!)), Data("jpeg".utf8))
        let proof = screenshot.proofFolder()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: proof.path).count, 200)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: proof.path)[.posixPermissions] as! NSNumber).intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: paths.last!)[.posixPermissions] as! NSNumber).intValue, 0o600)
        screenshot.cleanup(maxAge: -1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.last!))
    }
    func testSpaceInStateUsesRenamedHomeFallback() {
        let screenshot = Screenshot(folder: folder, stateDirectory: { self.folder.appendingPathComponent("Application Support") }, sources: [])
        XCTAssertEqual(screenshot.proofFolder(), Paths.homeDirectory().appendingPathComponent(".term-llm-computer/proof", isDirectory: true))
    }
    func testCleanupOnlyOldScreenshotsAndDeadCapturePNGs() throws {
        for name in ["old.jpeg", "new.jpeg", "capture-1.png", "notes.txt", "other.png"] {
            let path = folder.appendingPathComponent(name); try Data([0]).write(to: path)
            if name != "new.jpeg" { try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3601)], ofItemAtPath: path.path) }
        }
        let screenshot = Screenshot(folder: folder)
        screenshot.cleanup()
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)), ["new.jpeg", "notes.txt", "other.png"])
        screenshot.cleanup(maxAge: -1)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)), ["notes.txt", "other.png"])
        Screenshot(folder: folder.appendingPathComponent("absent")).cleanup()
    }
    func testNoImageFailsBeforeAskingForExtras() {
        var asked: [UInt32] = []
        let screenshot = screenshot(sources: [{ id, extra in asked.append(id); XCTAssertTrue(extra.isEmpty); return nil }])
        assertHarnessError("Taking the screenshot failed.") { _ = try screenshot.capture(fixtureWindow(), extras: [(9, .zero)]) }
        XCTAssertEqual(asked, [7])
    }
    func testMenuCompositionAndPixelMapping() throws {
        let images = [UInt32(7): fakeImage(), UInt32(9): fakeImage(20, 40)]
        let shot = try screenshot(sources: [{ id, _ in images[id] }]).capture(fixtureWindow(), extras: [(9, CGRect(x: 80, y: 70, width: 10, height: 20)), (11, CGRect(x: 0, y: 0, width: 5, height: 5))])
        XCTAssertEqual(shot.scale, 2); XCTAssertEqual(shot.origin, CGPoint(x: 60, y: 58)); XCTAssertEqual(shot.width, 64); XCTAssertEqual(shot.height, 64)
        XCTAssertEqual(shot.toScreen(x: 50, y: 50), CGPoint(x: 85, y: 83))
        let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: shot.path) as CFURL, nil)!
        XCTAssertEqual(CGImageSourceCreateImageAtIndex(source, 0, nil)?.height, 64)
    }
    func testUnusableSizeHasOwnError() {
        assertHarnessError("The screenshot has an unusable size: (64, 48)") { _ = try screenshot().capture(fixtureWindow(frame: .zero)) }
    }
    func testHungSourceTimesOutAndIsLeftAloneWhileFallbackWorks() throws {
        let release = DispatchSemaphore(value: 0)
        var calls = 0
        let screenshot = screenshot(sources: [{ _, _ in calls += 1; release.wait(); return nil }, { _, _ in fakeImage() }])
        let start = ProcessInfo.processInfo.systemUptime
        defer { release.signal() }
        XCTAssertEqual(try screenshot.capture(fixtureWindow()).width, 64)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
        XCTAssertEqual(try screenshot.capture(fixtureWindow()).width, 64)
        XCTAssertEqual(calls, 1); XCTAssertEqual(Screenshot.captureTimeout, 2); XCTAssertEqual(Screenshot.retryAfter, 60)
    }
    func testAnsweredNilRetriesNextTimeAndSourcesStayInOrder() throws {
        var asked: [String] = []
        let screenshot = screenshot(sources: [{ _, _ in asked.append("first"); return nil }, { _, _ in asked.append("second"); return fakeImage() }])
        _ = try screenshot.capture(fixtureWindow()); _ = try screenshot.capture(fixtureWindow())
        XCTAssertEqual(asked, ["first", "second", "first", "second"])
    }
    func testOneFailedImageDoesNotCostNextRead() throws {
        var gives: [CGImage?] = [nil, fakeImage()]
        let screenshot = screenshot(sources: [{ _, _ in gives.removeFirst() }])
        assertHarnessError("Taking the screenshot failed.") { _ = try screenshot.capture(fixtureWindow()) }
        XCTAssertEqual(try screenshot.capture(fixtureWindow()).width, 64)
    }
    func testChildArgumentsNonhiddenPathAndExitZeroWithoutFile() {
        var ran: [String] = []
        let screenshot = Screenshot(folder: folder, runner: { executable, args, timeout in ran = [executable] + args; XCTAssertEqual(timeout, 1.8) })
        XCTAssertNil(screenshot.toolImage(7)); XCTAssertEqual(Array(ran.prefix(5)), ["/usr/sbin/screencapture", "-x", "-o", "-l", "7"])
        XCTAssertFalse(URL(fileURLWithPath: ran.last!).lastPathComponent.hasPrefix(".")); XCTAssertFalse(FileManager.default.fileExists(atPath: ran.last!))
    }
    func testToolImageDecodedBeforeScratchFileIsRemoved() throws {
        let image = fakeImage()
        let screenshot = Screenshot(folder: folder, runner: { _, args, _ in
            let path = URL(fileURLWithPath: args.last!)
            let writer = CGImageDestinationCreateWithURL(path as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(writer, image, nil); XCTAssertTrue(CGImageDestinationFinalize(writer))
        })
        XCTAssertEqual(screenshot.toolImage(7)?.width, 64)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }
    func testCanCaptureUsesOnePointAndOnlyFileCounts() throws {
        for writes in [true, false] {
            let screenshot = Screenshot(folder: folder, runner: { _, args, _ in
                XCTAssertEqual(Array(args.prefix(2)), ["-x", "-R0,0,1,1"])
                if writes { try Data([1]).write(to: URL(fileURLWithPath: args.last!)) }
            })
            XCTAssertEqual(screenshot.canCapture(), writes)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
        }
    }
    func testToolFailureCleansScratchFile() throws {
        let screenshot = Screenshot(folder: folder, runner: { _, args, _ in try Data([1]).write(to: URL(fileURLWithPath: args.last!)); throw WireError.timedOut })
        XCTAssertNil(screenshot.toolImage(7)); XCTAssertFalse(screenshot.canCapture())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }
    func testChildProcessExitAndTimeoutWithoutAnyCapture() throws {
        try Screenshot.run("/usr/bin/true", arguments: [], timeout: 1)
        XCTAssertThrowsError(try Screenshot.run("/bin/sleep", arguments: ["5"], timeout: 0.02)) { XCTAssertEqual($0 as? WireError, .timedOut) }
    }
    func testConstructionDoesNotCaptureAndPhasesAreUnchanged() {
        let shots = folder.appendingPathComponent("shots")
        _ = Screenshot(folder: shots)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shots.path))
        XCTAssertEqual(Screenshot.phases, ["Capture Screenshot", "Write Screenshot File"])
        XCTAssertEqual(Screenshot.maxAge, 3600)
    }
}
