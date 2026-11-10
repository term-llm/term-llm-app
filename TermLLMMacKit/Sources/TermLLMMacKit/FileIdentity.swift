import Darwin
import Foundation
import os

/// Identity of an unchanged file. Rewriting its contents changes the
/// modification and status-change times, and atomic replacement changes the
/// inode, so a matching identity means a previously checked file was not
/// replaced. Used only to avoid re-reading a large executable while polling.
struct FileIdentity: Hashable, Sendable {
    let path: String
    let device: Int64
    let inode: UInt64
    let size: Int64
    let modified: [Int]
    let changed: [Int]

    init?(_ url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        path = url.standardizedFileURL.path
        device = Int64(info.st_dev)
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        modified = [Int(info.st_mtimespec.tv_sec), Int(info.st_mtimespec.tv_nsec)]
        changed = [Int(info.st_ctimespec.tv_sec), Int(info.st_ctimespec.tv_nsec)]
    }
}

/// Process-wide memo for checks of unchanged files.
final class FileCheckCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private let values = OSAllocatedUnfairLock<[Key: Value]>(initialState: [:])

    func value(for key: Key) -> Value? {
        values.withLock { $0[key] }
    }

    func set(_ value: Value, for key: Key) {
        values.withLock { $0[key] = value }
    }
}
