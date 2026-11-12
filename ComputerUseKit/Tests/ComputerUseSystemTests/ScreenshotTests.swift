import ComputerUseCore
import Foundation
import ImageIO
import XCTest
import os
@testable import ComputerUseSystem

final class ScreenshotTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("cu-screenshot-\(UUID().uuidString)")
        try UnixSocket.makeOwnFolder(folder.path)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    private func screenshot(sources: [Screenshot.Source] = [{ _, _ in fakeImage() }]) -> Screenshot {
        let state = folder.appendingPathComponent("state")
        return Screenshot(folder: folder.appendingPathComponent("shots"), stateDirectory: { state }, sources: sources, appName: { _ in "Font Book" })
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
        let state = folder.appendingPathComponent("Application Support")
        let screenshot = Screenshot(folder: folder, stateDirectory: { state }, sources: [])
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
        let asked = OSAllocatedUnfairLock<[UInt32]>(initialState: [])
        let screenshot = screenshot(sources: [{ id, extra in asked.withLock { $0.append(id) }; XCTAssertTrue(extra.isEmpty); return nil }])
        assertHarnessError("Taking the screenshot failed.") { _ = try screenshot.capture(fixtureWindow(), extras: [(9, .zero)]) }
        XCTAssertEqual(asked.withLock { $0 }, [7])
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
        let release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let screenshot = screenshot(sources: [{ _, _ in
            defer { finished.signal() }
            calls.withLock { $0 += 1 }; release.wait(); return nil
        }, { _, _ in fakeImage() }])
        let start = ProcessInfo.processInfo.systemUptime
        defer {
            release.signal()
            XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        }
        XCTAssertEqual(try screenshot.capture(fixtureWindow()).width, 64)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
        XCTAssertEqual(try screenshot.capture(fixtureWindow()).width, 64)
        XCTAssertEqual(calls.withLock { $0 }, 1); XCTAssertEqual(Screenshot.captureTimeout, 2); XCTAssertEqual(Screenshot.retryAfter, 60)
    }
    func testAnsweredNilRetriesNextTimeAndSourcesStayInOrder() throws {
        let asked = OSAllocatedUnfairLock<[String]>(initialState: [])
        let screenshot = screenshot(sources: [{ _, _ in asked.withLock { $0.append("first") }; return nil }, { _, _ in asked.withLock { $0.append("second") }; return fakeImage() }])
        _ = try screenshot.capture(fixtureWindow()); _ = try screenshot.capture(fixtureWindow())
        XCTAssertEqual(asked.withLock { $0 }, ["first", "second", "first", "second"])
    }
    func testOneFailedImageDoesNotCostNextRead() throws {
        let gives = OSAllocatedUnfairLock<[CGImage?]>(initialState: [nil, fakeImage()])
        let screenshot = screenshot(sources: [{ _, _ in gives.withLock { $0.removeFirst() } }])
        assertHarnessError("Taking the screenshot failed.") { _ = try screenshot.capture(fixtureWindow()) }
        XCTAssertEqual(try screenshot.capture(fixtureWindow()).width, 64)
    }
    func testSharedInstanceUsesInjectedDependenciesAcrossCaptureWorkers() throws {
        let shots = folder.appendingPathComponent("shots"), state = folder.appendingPathComponent("state")
        let image = fakeImage()
        let arguments = OSAllocatedUnfairLock<[[String]]>(initialState: [])
        let names = OSAllocatedUnfairLock<[pid_t]>(initialState: [])
        let ticks = OSAllocatedUnfairLock(initialState: 0)
        // No sources override: exercise the default source -> toolImage path,
        // but the runner writes fixture pixels and never launches a capture tool.
        let screenshot = Screenshot(folder: shots, stateDirectory: { state }, captureTool: "fixture-capture", runner: { tool, args, timeout in
            XCTAssertEqual(tool, "fixture-capture"); XCTAssertEqual(timeout, Screenshot.toolTimeout)
            arguments.withLock { $0.append(args) }
            let writer = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args.last!) as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(writer, image, nil); XCTAssertTrue(CGImageDestinationFinalize(writer))
        }, uptime: {
            ticks.withLock { $0 += 1; return Double($0) }
        }, appName: { pid in
            names.withLock { $0.append(pid) }; return "Fixture"
        })
        let paths = OSAllocatedUnfairLock<[String]>(initialState: [])
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            do {
                XCTAssertEqual(screenshot.proofFolder(), state.appendingPathComponent("proof", isDirectory: true))
                let shot = try screenshot.capture(fixtureWindow())
                XCTAssertEqual(shot.width, 64); XCTAssertEqual(shot.height, 48)
                paths.withLock { $0.append(shot.path) }
            } catch { XCTFail("Fixture capture failed: \(error)") }
        }
        let captured = paths.withLock { $0 }, ran = arguments.withLock { $0 }
        XCTAssertEqual(captured.count, 16); XCTAssertEqual(Set(captured).count, 16)
        XCTAssertEqual(names.withLock { $0 }, Array(repeating: 77, count: 16))
        XCTAssertEqual(ticks.withLock { $0 }, 16 * 5)
        XCTAssertEqual(ran.count, 16); XCTAssertEqual(Set(ran.compactMap(\.last)).count, 16)
        XCTAssertTrue(ran.allSatisfy { Array($0.prefix(4)) == ["-x", "-o", "-l", "7"] })
        for path in captured {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
            XCTAssertEqual(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width, 64)
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: shots.path)), Set(captured.map { URL(fileURLWithPath: $0).lastPathComponent }))
    }
    func testCooldownIsSharedAcrossWorkersAndRetriesAtDeadline() {
        let release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let clock = OSAllocatedUnfairLock<TimeInterval>(initialState: 100)
        let asked = OSAllocatedUnfairLock<[UInt32]>(initialState: [])
        let screenshot = Screenshot(folder: folder, sources: [{ id, _ in
            let first = asked.withLock { $0.append(id); return $0.count == 1 }
            if first {
                defer { finished.signal() }
                release.wait()
                return nil
            }
            return fakeImage()
        }, { _, _ in fakeImage(32, 24) }], uptime: { clock.withLock { $0 } })
        defer {
            release.signal()
            XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        }
        XCTAssertEqual(screenshot.firstImage(7)?.width, 32) // Hang cools only the first source.
        clock.withLock { $0 = 159 }
        DispatchQueue.concurrentPerform(iterations: 32) { id in
            XCTAssertEqual(screenshot.firstImage(UInt32(id + 100))?.width, 32)
        }
        XCTAssertEqual(asked.withLock { $0 }, [7])
        clock.withLock { $0 = 160 } // Exact deadline is eligible, not one tick later.
        XCTAssertEqual(screenshot.firstImage(9)?.width, 64)
        XCTAssertEqual(asked.withLock { $0 }, [7, 9])
    }
    func testConcurrentTimeoutCannotShortenANewerCooldown() {
        let release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let sampled = DispatchSemaphore(value: 0), publish = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let clock = OSAllocatedUnfairLock(initialState: (time: TimeInterval(100), reads: 0))
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let screenshot = Screenshot(folder: folder, sources: [{ _, _ in
            if calls.withLock({ $0 += 1; return $0 <= 2 }) {
                defer { finished.signal() }
                release.wait()
                return nil
            }
            return fakeImage()
        }, { _, _ in fakeImage(32, 24) }], uptime: {
            let sample = clock.withLock { state in
                state.reads += 1
                let sample = (state.time, state.reads)
                if state.reads == 3 { state.time = 110 }
                return sample
            }
            if sample.1 == 3 {
                sampled.signal() // The first timeout sampled 100 but has not published.
                XCTAssertEqual(publish.wait(timeout: .now() + 10), .success)
            }
            return sample.0
        })
        defer {
            publish.signal()
            for _ in 0..<2 { release.signal() }
            for _ in 0..<2 { XCTAssertEqual(finished.wait(timeout: .now() + 5), .success) }
        }
        for _ in 0..<2 {
            DispatchQueue.global().async {
                XCTAssertEqual(screenshot.firstImage(7)?.width, 32)
                done.signal()
            }
        }
        XCTAssertEqual(sampled.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success) // The newer timeout published 170.
        publish.signal() // Now allow the stale 160 deadline to publish last.
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        clock.withLock { $0.time = 165 }
        XCTAssertEqual(screenshot.firstImage(7)?.width, 32)
        XCTAssertEqual(calls.withLock { $0 }, 2)
    }
    func testTimeoutClockCanReenterWithoutCooldownLock() {
        let release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let slot = OSAllocatedUnfairLock<Screenshot?>(initialState: nil)
        let reads = OSAllocatedUnfairLock(initialState: 0), calls = OSAllocatedUnfairLock(initialState: 0)
        let screenshot = Screenshot(folder: folder, sources: [{ _, _ in
            if calls.withLock({ $0 += 1; return $0 == 1 }) {
                defer { finished.signal() }
                release.wait()
                return nil
            }
            return fakeImage()
        }], uptime: {
            let read = reads.withLock { $0 += 1; return $0 }
            if read == 2 { // The timestamp used to write the timeout cooldown.
                let nested = DispatchSemaphore(value: 0)
                let owner = slot.withLock { $0! }
                DispatchQueue.global().async {
                    XCTAssertEqual(owner.firstImage(9)?.width, 64)
                    nested.signal()
                }
                // A bounded wait detects a held cooldown lock without wedging
                // the suite: the nested worker can finish when this returns.
                XCTAssertEqual(nested.wait(timeout: .now() + 5), .success)
            }
            return 100
        })
        slot.withLock { $0 = screenshot }
        defer {
            slot.withLock { $0 = nil }
            release.signal()
            XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        }
        XCTAssertNil(screenshot.firstImage(7))
        XCTAssertNil(screenshot.firstImage(7)) // The completed timeout still cools the source.
        XCTAssertEqual(calls.withLock { $0 }, 2)
        XCTAssertEqual(reads.withLock { $0 }, 4)
    }
    func testChildArgumentsNonhiddenPathAndExitZeroWithoutFile() {
        let arguments = OSAllocatedUnfairLock<[String]>(initialState: [])
        let screenshot = Screenshot(folder: folder, runner: { executable, args, timeout in
            arguments.withLock { $0 = [executable] + args }; XCTAssertEqual(timeout, 1.8)
        })
        XCTAssertNil(screenshot.toolImage(7))
        let ran = arguments.withLock { $0 }
        XCTAssertEqual(Array(ran.prefix(5)), ["/usr/sbin/screencapture", "-x", "-o", "-l", "7"])
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
