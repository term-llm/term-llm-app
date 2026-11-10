import CoreGraphics
import ComputerUseCore
import Foundation

/// Never unlock: that would mean typing the login password, and this tool never
/// types one. This ~2 ms session-dictionary read goes first on every call, because
/// accessibility reads behind the lock screen all come back empty.
public enum LockScreen {
    public static let lockedKey = "CGSSessionScreenIsLocked"
    public static func locked(session: () -> [String: Any]? = { CGSessionCopyCurrentDictionary() as? [String: Any] }) -> Bool {
        guard let value = session()?[lockedKey] else { return false }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return !text.isEmpty }
        return false
    }
    /// Fail before anything touches an app. The caller supplies whether this is a
    /// state read so the refusal tells the model exactly why there is no AX text.
    // HarnessExecutor calls this after permissions, before the person gate/app FIFO.
    public static func gate(stateRead: Bool, isLocked: () -> Bool = { locked() }) throws {
        if isLocked() { throw Errors.locked(stateRead: stateRead) }
    }
}
