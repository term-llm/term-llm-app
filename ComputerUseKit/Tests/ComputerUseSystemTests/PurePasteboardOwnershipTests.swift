import ComputerUseCore
import Foundation
import os
import XCTest
@testable import ComputerUseSystem

private typealias Pasteboard = ComputerUseSystem.Pasteboard

// Safety contract: no native board factory, AppKit items, HTML importer, input,
// run loop or helper runtime. Every Pasteboard below has all dependencies injected.
// The only native-boundary test passes a counter closure, never an SDK operation.
private final class FakeOwnedBoard: Sendable {
    struct State: Sendable {
        var items: Pasteboard.Snapshot = [[Pasteboard.plain: Data("person".utf8), "fake.rich": Data([0, 1, 2])]]
        var count = 7
        var provider: LazyPasteData?
        var events: [String] = []
        var writesSucceed = true
        var restoresSucceed = true
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    var items: Pasteboard.Snapshot { state.withLock { $0.items } }
    var provider: LazyPasteData? { state.withLock { $0.provider } }
    var backend: Pasteboard.Backend {
        .init(snapshot: {
            self.state.withLock { $0.events.append("snapshot"); return $0.items }
        }, write: { provider in
            self.state.withLock {
                $0.events.append("write")
                guard $0.writesSucceed else { return nil }
                $0.count += 1; $0.items = [provider.payload]; $0.provider = provider
                return $0.count
            }
        }, restore: { saved, ours in
            self.state.withLock {
                $0.events.append("restore")
                guard $0.restoresSucceed, $0.count == ours else { return false }
                $0.count += 1; $0.items = saved; $0.provider = nil
                return true
            }
        })
    }
    func consume(_ kind: String = Pasteboard.plain) -> Data? {
        // Never call into the provider while holding fixture state's lock.
        guard let provider else { return nil }
        let data = provider.payload[kind]
        provider.markRead()
        return data
    }
    func personCopy() {
        state.withLock { $0.count += 1; $0.items = [[Pasteboard.plain: Data("new person copy".utf8)]]; $0.provider = nil }
    }
}

private struct PasteFixture: Sendable {
    let fake = FakeOwnedBoard()
    let folder: URL
    var path: URL { folder.appendingPathComponent(Pasteboard.restoreFile) }
    init() throws {
        // Verification sets TMPDIR to this worktree's ignored output/ directory.
        folder = try temporaryFolder()
    }
    func remove() { try? FileManager.default.removeItem(at: folder) }
    func paste(wait: @escaping Pasteboard.Wait = { Pasteboard.wait($0, timeout: $1, poll: $2) }) -> Pasteboard {
        let backend = fake.backend, folder = folder
        return Pasteboard(board: { backend }, stateDirectory: { folder }, wait: wait)
    }
    func recovery(items: Pasteboard.Snapshot, count: Int) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["items": items, "count": count], format: .xml, options: 0)
        try data.write(to: path)
    }
    var fileExists: Bool { FileManager.default.fileExists(atPath: path.path) }
}

final class PurePasteboardOwnershipTests: XCTestCase {
    func testCheckedSendableProviderHasImmutablePayloadAndConcurrentReceipt() {
        func requireSendable<T: Sendable>(_: T) {}
        var original = [Pasteboard.plain: Data("original".utf8)]
        let provider = LazyPasteData(payload: original)
        original[Pasteboard.plain] = Data("changed".utf8)
        requireSendable(provider)
        requireSendable(FakeOwnedBoard().backend)
        XCTAssertFalse(provider.wasRead)
        XCTAssertEqual(provider.payload[Pasteboard.plain], Data("original".utf8))
        DispatchQueue.concurrentPerform(iterations: 128) { index in
            XCTAssertEqual(provider.payload[Pasteboard.plain], Data("original".utf8))
            if index.isMultiple(of: 2) { provider.markRead() }
            _ = provider.wasRead
        }
        XCTAssertTrue(provider.wasRead)
    }

    func testReceiptRestoresAllOriginalRepresentationsAndTightensRecoveryMode() throws {
        let f = try PasteFixture(); defer { f.remove() }
        let saved = f.fake.items
        try Data().write(to: f.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.path.path)
        let paste = f.paste()
        func requireSendable<T: Sendable>(_: T) {}
        requireSendable(paste)
        try paste.paste("tool", format: "text", sendPasteKey: {
            XCTAssertFalse(try XCTUnwrap(f.fake.provider).wasRead)
            let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: f.path), format: nil) as? [String: Any])
            XCTAssertEqual(plist["items"] as? Pasteboard.Snapshot, saved)
            XCTAssertEqual(plist["count"] as? Int, 8)
            let mode = try FileManager.default.attributesOfItem(atPath: f.path.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600)
            let folderMode = try FileManager.default.attributesOfItem(atPath: f.folder.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(folderMode?.intValue, 0o700)
            XCTAssertEqual(f.fake.consume(), Data("tool".utf8))
            XCTAssertTrue(try XCTUnwrap(f.fake.provider).wasRead)
        })
        XCTAssertEqual(f.fake.items, saved)
        XCTAssertEqual(f.fake.state.withLock { $0.events }, ["snapshot", "write", "restore"])
        XCTAssertFalse(f.fileExists)
    }

    func testEmptySnapshotRemainsEmpty() throws {
        let f = try PasteFixture(); defer { f.remove() }
        f.fake.state.withLock { $0.items = [] }
        try f.paste().paste("tool", format: "text", sendPasteKey: { _ = f.fake.consume() })
        XCTAssertEqual(f.fake.items, [])
        XCTAssertFalse(f.fileExists)
    }

    func testDelayedConcurrentReceiptUnblocksWorkerWaitWithoutMainLoop() throws {
        let f = try PasteFixture(); defer { f.remove() }
        let saved = f.fake.items
        let waiting = DispatchSemaphore(value: 0), done = DispatchGroup()
        let paste = f.paste(wait: { predicate, timeout, poll in
            XCTAssertFalse(Thread.isMainThread)
            waiting.signal()
            return Pasteboard.wait(predicate, timeout: timeout, poll: poll)
        })
        done.enter()
        DispatchQueue.global().async {
            defer { done.leave() }
            do { try paste.paste("tool", format: "text", sendPasteKey: {}, timeout: 5) }
            catch { XCTFail("Delayed receipt: \(error)") }
        }
        XCTAssertEqual(waiting.wait(timeout: .now() + 5), .success)
        XCTAssertFalse(try XCTUnwrap(f.fake.provider).wasRead)
        XCTAssertTrue(f.fileExists)
        done.enter()
        DispatchQueue.global().async {
            defer { done.leave() }
            XCTAssertEqual(f.fake.consume(), Data("tool".utf8))
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(f.fake.items, saved)
        XCTAssertFalse(f.fileExists)
    }

    func testUnreadTimeoutRestoresWithoutCallingLanded() throws {
        let f = try PasteFixture(); defer { f.remove() }
        let saved = f.fake.items
        XCTAssertThrowsError(try f.paste().paste("tool", format: "text", sendPasteKey: {}, timeout: 0, landed: {
            XCTFail("Unread text must not enter landing wait"); return true
        })) { XCTAssertEqual($0 as? HarnessError, Errors.make("paste_not_read")) }
        XCTAssertEqual(f.fake.items, saved)
        XCTAssertFalse(f.fileExists)
    }

    func testNewerCopyWinsEvenWhenUnreadTimeoutAlsoFails() throws {
        let f = try PasteFixture(); defer { f.remove() }
        XCTAssertThrowsError(try f.paste().paste("tool", format: "text", sendPasteKey: { f.fake.personCopy() }, timeout: 0)) {
            XCTAssertEqual($0 as? HarnessError, Errors.make("paste_conflict"))
        }
        XCTAssertEqual(f.fake.items, [[Pasteboard.plain: Data("new person copy".utf8)]])
        XCTAssertFalse(f.fileExists)
    }

    func testNewerCopyAfterReceiptAlsoWins() throws {
        let f = try PasteFixture(); defer { f.remove() }
        XCTAssertThrowsError(try f.paste().paste("tool", format: "text", sendPasteKey: {
            _ = f.fake.consume(); f.fake.personCopy()
        })) { XCTAssertEqual($0 as? HarnessError, Errors.make("paste_conflict")) }
        XCTAssertEqual(f.fake.items, [[Pasteboard.plain: Data("new person copy".utf8)]])
        XCTAssertFalse(f.fileExists)
    }

    func testSendExceptionHasPrecedenceOverFailedRestore() throws {
        let f = try PasteFixture(); defer { f.remove() }
        f.fake.state.withLock { $0.restoresSucceed = false }
        XCTAssertThrowsError(try f.paste().paste("tool", format: "text", sendPasteKey: { throw WireError.closed })) {
            guard case WireError.closed = $0 else { return XCTFail("Send exception was replaced: \($0)") }
        }
        XCTAssertEqual(f.fake.state.withLock { $0.events }, ["snapshot", "write", "restore"])
        XCTAssertFalse(f.fileExists)
    }

    func testCancellationRestoresAndReleasesGlobalTransaction() throws {
        let f = try PasteFixture(); defer { f.remove() }
        let saved = f.fake.items
        let cancellation = HarnessError(code: 1, name: "cancelled", message: "fake cancellation", cancelled: true)
        let paste = f.paste()
        XCTAssertThrowsError(try paste.paste("tool", format: "text", sendPasteKey: { throw cancellation })) {
            XCTAssertEqual($0 as? HarnessError, cancellation)
        }
        XCTAssertEqual(f.fake.items, saved)
        XCTAssertFalse(f.fileExists)
        try paste.paste("next", format: "text", sendPasteKey: { _ = f.fake.consume() })
        XCTAssertEqual(f.fake.items, saved)
    }

    func testSendExceptionDoesNotOverwriteNewPersonCopy() throws {
        let f = try PasteFixture(); defer { f.remove() }
        XCTAssertThrowsError(try f.paste().paste("tool", format: "text", sendPasteKey: {
            f.fake.personCopy(); throw WireError.closed
        })) { guard case WireError.closed = $0 else { return XCTFail("Expected send error") } }
        XCTAssertEqual(f.fake.items, [[Pasteboard.plain: Data("new person copy".utf8)]])
        XCTAssertFalse(f.fileExists)
    }

    func testWriteFailureSkipsFileWaitRestoreAndSend() throws {
        let f = try PasteFixture(); defer { f.remove() }
        f.fake.state.withLock { $0.writesSucceed = false }
        let backend = f.fake.backend
        let paste = Pasteboard(board: { backend }, stateDirectory: { XCTFail("No recovery file before write"); return f.folder },
                               wait: { _, _, _ in XCTFail("No wait before write"); return false })
        XCTAssertThrowsError(try paste.paste("tool", format: "text", sendPasteKey: { XCTFail("No send before write") })) {
            XCTAssertEqual($0 as? HarnessError, Errors.make("paste_write_failed"))
        }
        XCTAssertEqual(f.fake.state.withLock { $0.events }, ["snapshot", "write"])
        XCTAssertFalse(f.fileExists)
    }

    func testRecoverySymlinkRefusedAndDestinationUnchanged() throws {
        let f = try PasteFixture(); defer { f.remove() }
        let saved = f.fake.items, target = f.folder.appendingPathComponent("private-target")
        let secret = Data("do not truncate".utf8)
        try secret.write(to: target)
        try FileManager.default.createSymbolicLink(at: f.path, withDestinationURL: target)
        XCTAssertThrowsError(try f.paste().paste("tool", format: "text", sendPasteKey: { XCTFail("Save failed before send") }))
        XCTAssertEqual(try Data(contentsOf: target), secret)
        XCTAssertEqual(f.fake.items, saved)
        XCTAssertFalse(f.fileExists)
        // An exception must also release the global lock for a following paste.
        try f.paste().paste("next", format: "text", sendPasteKey: { _ = f.fake.consume() })
    }

    func testLandingTimeoutIsNonfatalWithExactReadAndLandingPolls() throws {
        let f = try PasteFixture(); defer { f.remove() }
        let saved = f.fake.items
        let calls = OSAllocatedUnfairLock(initialState: [(Double, Double)]())
        let paste = f.paste(wait: { done, timeout, poll in
            let first = calls.withLock { $0.append((timeout, poll)); return $0.count == 1 }
            return first ? done() : false
        })
        try paste.paste("tool", format: "text", sendPasteKey: { _ = f.fake.consume() }, timeout: 0.125, landed: { false })
        XCTAssertEqual(calls.withLock { $0.map { $0.0 } }, [0.125, Pasteboard.landTimeout])
        XCTAssertEqual(calls.withLock { $0.map { $0.1 } }, [0.01, Pasteboard.landPoll])
        XCTAssertEqual(f.fake.items, saved)
        XCTAssertFalse(f.fileExists)
    }

    func testLandedPredicateIsSynchronousOperationLocalState() throws {
        let f = try PasteFixture(); defer { f.remove() }
        // Deliberately non-Sendable/local: wait may neither escape nor reschedule it.
        var samples: [Data] = []
        try f.paste().paste("tool", format: "text", sendPasteKey: { _ = f.fake.consume() }, landed: {
            samples.append(f.fake.consume()!)
            return samples.count == 3
        })
        XCTAssertEqual(samples, Array(repeating: Data("tool".utf8), count: 3))
        XCTAssertFalse(f.fileExists)
    }

    func testWaitSamplesPredicateBeforeZeroTimeout() {
        var samples = 0
        XCTAssertFalse(Pasteboard.wait({ samples += 1; return false }, timeout: 0))
        XCTAssertEqual(samples, 1)
        XCTAssertTrue(Pasteboard.wait({ true }, timeout: 0))
    }

    func testCrashRecoveryRestoresMatchingCountAndDeletesFile() throws {
        let f = try PasteFixture(); defer { f.remove() }
        let saved = f.fake.items
        f.fake.personCopy()
        try f.recovery(items: saved, count: f.fake.state.withLock { $0.count })
        f.paste().restoreSaved()
        XCTAssertEqual(f.fake.items, saved)
        XCTAssertEqual(f.fake.state.withLock { $0.events }, ["restore"])
        XCTAssertFalse(f.fileExists)
    }

    func testStaleRecoveryNeverOverwritesPerson() throws {
        let f = try PasteFixture(); defer { f.remove() }
        let saved = f.fake.items
        f.fake.personCopy()
        let newer = f.fake.items
        try f.recovery(items: saved, count: 7)
        f.paste().restoreSaved()
        XCTAssertEqual(f.fake.items, newer)
        XCTAssertFalse(f.fileExists)
    }

    func testAbsentAndCorruptRecoveryNeverCreateBackend() throws {
        let f = try PasteFixture(); defer { f.remove() }
        let paste = Pasteboard(board: {
            XCTFail("Invalid recovery must not create any backend, especially a live board")
            return .init(snapshot: { XCTFail("No snapshot"); return [] }, write: { _ in XCTFail("No write"); return nil }, restore: { _, _ in XCTFail("No restore"); return false })
        }, stateDirectory: { f.folder }, wait: { _, _, _ in XCTFail("No recovery wait"); return false })
        paste.restoreSaved()
        for data in [Data(), Data("not a plist".utf8), try PropertyListSerialization.data(fromPropertyList: ["count": "invalid", "items": []], format: .xml, options: 0)] {
            try data.write(to: f.path)
            paste.restoreSaved()
            XCTAssertFalse(f.fileExists)
        }
    }

    func testFakeCallbacksStayOnWorkerAndMayReenterReceiptAndPureHelpers() throws {
        let f = try PasteFixture(); defer { f.remove() }
        let done = DispatchGroup(), calls = OSAllocatedUnfairLock(initialState: [String]())
        done.enter()
        DispatchQueue.global().async {
            defer { done.leave() }
            let record: @Sendable (String) -> Void = { name in
                XCTAssertFalse(Thread.isMainThread)
                XCTAssertEqual(Pasteboard.markdownHTML("x"), "<p>x</p>")
                XCTAssertTrue(Pasteboard.wait({ true }, timeout: 0))
                _ = f.fake.provider?.wasRead
                calls.withLock { $0.append(name) }
            }
            let original = f.fake.backend
            let backend = Pasteboard.Backend(snapshot: { record("snapshot"); return original.snapshot() },
                                             write: { record("write"); return original.write($0) },
                                             restore: { record("restore"); return original.restore($0, $1) })
            let paste = Pasteboard(board: { record("factory"); return backend }, stateDirectory: { record("directory"); return f.folder },
                                   wait: { predicate, _, _ in record("wait"); return predicate() })
            do { try paste.paste("tool", format: "text", sendPasteKey: { record("send"); _ = f.fake.consume() }) }
            catch { XCTFail("Fake paste failed: \(error)") }
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(calls.withLock { $0 }, ["factory", "snapshot", "write", "directory", "send", "wait", "restore"])
    }

    func testNativeBoundaryRejectsWorkerFallbackWithoutExecutingWork() {
        XCTAssertFalse(MainThread.isRunning, "This suite must not start an AppKit loop")
        let done = DispatchGroup(), executions = OSAllocatedUnfairLock(initialState: 0)
        done.enter()
        DispatchQueue.global().async {
            defer { done.leave() }
            // This is a pure counter, NOT a native factory or importer.
            let value = Pasteboard.Backend.onMain { executions.withLock { $0 += 1 }; return 42 }
            XCTAssertNil(value)
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(executions.withLock { $0 }, 0)
    }

    @MainActor
    func testNativeBoundaryAllowsMainInlineWithoutSDKObjects() {
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertEqual(Pasteboard.Backend.onMain { 42 }, 42)
    }

    func testGlobalSerializationSpansEntireTransactionAcrossInstances() throws {
        let a = try PasteFixture(), b = try PasteFixture()
        defer { a.remove(); b.remove() }
        let enteredA = DispatchSemaphore(value: 0), releaseA = DispatchSemaphore(value: 0)
        let attemptedB = DispatchSemaphore(value: 0), enteredB = DispatchSemaphore(value: 0)
        let done = DispatchGroup()
        done.enter()
        DispatchQueue.global().async {
            defer { done.leave() }
            do { try a.paste().paste("a", format: "text", sendPasteKey: {
                enteredA.signal()
                XCTAssertEqual(releaseA.wait(timeout: .now() + 5), .success)
                _ = a.fake.consume()
            }) } catch { XCTFail("First paste: \(error)") }
        }
        XCTAssertEqual(enteredA.wait(timeout: .now() + 5), .success)
        done.enter()
        DispatchQueue.global().async {
            defer { done.leave() }
            let backend = b.fake.backend
            let paste = Pasteboard(board: { enteredB.signal(); return backend }, stateDirectory: { b.folder })
            attemptedB.signal()
            do { try paste.paste("b", format: "text", sendPasteKey: { _ = b.fake.consume() }) }
            catch { XCTFail("Second paste: \(error)") }
        }
        XCTAssertEqual(attemptedB.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(enteredB.wait(timeout: .now() + 0.1), .timedOut, "Factory must wait too, not merely sendPasteKey")
        XCTAssertTrue(a.fileExists)
        XCTAssertFalse(b.fileExists)
        releaseA.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(enteredB.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(a.fileExists); XCTAssertFalse(b.fileExists)
        XCTAssertEqual(a.fake.items[0][Pasteboard.plain], Data("person".utf8))
        XCTAssertEqual(b.fake.items[0][Pasteboard.plain], Data("person".utf8))
    }

    func testOneCheckedInstanceCanBeSharedByConcurrentWorkers() throws {
        let f = try PasteFixture(); defer { f.remove() }
        let paste = f.paste(), saved = f.fake.items
        let counts = OSAllocatedUnfairLock(initialState: (active: 0, peak: 0, completed: 0))
        let done = DispatchGroup()
        done.enter()
        DispatchQueue.global().async {
            defer { done.leave() }
            DispatchQueue.concurrentPerform(iterations: 16) { _ in
                do {
                    try paste.paste("tool", format: "text", sendPasteKey: {
                        XCTAssertFalse(Thread.isMainThread)
                        counts.withLock { $0.active += 1; $0.peak = max($0.peak, $0.active) }
                        Thread.sleep(forTimeInterval: 0.001)
                        _ = f.fake.consume()
                        counts.withLock { $0.active -= 1; $0.completed += 1 }
                    })
                } catch { XCTFail("Concurrent paste: \(error)") }
            }
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(counts.withLock { $0.peak }, 1)
        XCTAssertEqual(counts.withLock { $0.completed }, 16)
        XCTAssertEqual(f.fake.items, saved)
        XCTAssertFalse(f.fileExists)
    }

    func testCrashRecoveryWaitsForActivePasteThenSeesCleanup() throws {
        let f = try PasteFixture(); defer { f.remove() }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let attempted = DispatchSemaphore(value: 0), recovered = DispatchSemaphore(value: 0)
        let done = DispatchGroup(), paste = f.paste()
        done.enter()
        DispatchQueue.global().async {
            defer { done.leave() }
            do { try paste.paste("tool", format: "text", sendPasteKey: {
                entered.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                _ = f.fake.consume()
            }) } catch { XCTFail("Paste: \(error)") }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        done.enter()
        DispatchQueue.global().async {
            defer { done.leave() }
            attempted.signal(); paste.restoreSaved(); recovered.signal()
        }
        XCTAssertEqual(attempted.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(recovered.wait(timeout: .now() + 0.1), .timedOut)
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(recovered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(f.fake.state.withLock { $0.events }, ["snapshot", "write", "restore"])
        XCTAssertFalse(f.fileExists)
    }
}
