import Foundation
import os

/// One question to the person. Identity, not equal text, controls answering once.
/// Asked from a worker; the panel answers it on the main thread.
public final class Ask: Sendable {
    public let title: String
    public let subtitle: String?
    public let choices: [String]
    public let onAnswer: @Sendable (String) -> Void
    public init(
        title: String, subtitle: String? = nil, choices: [String],
        onAnswer: @escaping @Sendable (String) -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.choices = choices
        self.onAnswer = onAnswer
    }
}

/// Waiting questions, the first on screen (used on the main thread in the helper).
/// A question is answered once, even with reentrant UI.
public final class AskQueue: Sendable {
    private let waiting = OSAllocatedUnfairLock<[Ask]>(initialState: [])
    public var asks: [Ask] { waiting.withLock { $0 } }
    public init() {}
    public func append(_ ask: Ask) { waiting.withLock { $0.append(ask) } }
    public func withdraw(title: String) { waiting.withLock { $0.removeAll { $0.title == title } } }
    public func answer(_ ask: Ask, choice: String) {
        let removed = waiting.withLock { asks -> Bool in
            guard let index = asks.firstIndex(where: { $0 === ask }), ask.choices.contains(choice)
            else {
                return false
            }
            asks.remove(at: index)
            return true
        }
        // Outside the lock: the answer may append, withdraw or answer again.
        if removed { ask.onAnswer(choice) }
    }
}

public enum PanelGeometry {
    public static let width = 340.0, margin = 16.0
    /// Top right of the visible screen (AppKit coordinates, y up).
    public static func origin(size: CGSize, visible: CGRect) -> CGPoint {
        CGPoint(x: visible.maxX - size.width - margin, y: visible.maxY - size.height - margin)
    }
}

/// A call running, or a call began/ended within the last three seconds. Clock is
/// supplied so tests never create windows or install keyboard monitors.
public struct ActivityWindow {
    public static let linger = 3.0
    public private(set) var working = false
    public private(set) var changed: TimeInterval?
    public init() {}
    public mutating func update(working: Bool, now: TimeInterval) {
        self.working = working
        changed = now
    }
    public func visible(now: TimeInterval) -> Bool {
        working || changed.map { now < $0 + Self.linger } == true
    }
    public func remaining(now: TimeInterval) -> TimeInterval {
        working ? .infinity : max(0, (changed ?? -.infinity) + Self.linger - now)
    }
}
