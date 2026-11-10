import AppKit
import ComputerUseCore

/// A panel that can never become key/main, even after a click on a button.
final class PresencePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The questions waiting for the person, one at a time, top right. Main thread only.
@MainActor
public final class Panel: NSObject {
    public static let shared = Panel()
    public let questions = AskQueue()
    private var shown: Ask?, panel: NSPanel?
    public func append(_ ask: Ask) {
        precondition(Thread.isMainThread)
        questions.append(ask)
        draw()
    }
    public func withdraw(title: String) {
        precondition(Thread.isMainThread)
        questions.withdraw(title: title)
        draw()
    }
    public func draw() {
        precondition(Thread.isMainThread)
        let first = questions.asks.first
        if first === shown { return }
        panel?.orderOut(nil)
        panel = nil
        shown = first
        guard let ask = first, let screen = NSScreen.screens.first else { return }
        let made = Self.makePanel(ask, target: self)
        made.setFrameOrigin(
            PanelGeometry.origin(size: made.frame.size, visible: screen.visibleFrame))
        panel = made
        made.orderFrontRegardless()
    }
    /// Constructed off screen; orderFront is exclusively draw's responsibility.
    public static func makePanel(_ ask: Ask, target: AnyObject) -> NSPanel {
        precondition(Thread.isMainThread)
        let made = PresencePanel(
            contentRect: CGRect(x: 0, y: 0, width: PanelGeometry.width, height: 10),
            styleMask: [.titled, .utilityWindow, .hudWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        made.title = product
        made.level = .floating
        made.isFloatingPanel = true
        made.becomesKeyOnlyIfNeeded = true
        made.hidesOnDeactivate = false
        made.isReleasedWhenClosed = false
        made.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        var labels: [NSView] = []
        for (text, font) in [(ask.title, NSFont.boldSystemFont(ofSize: 13))]
            + (ask.subtitle.map { [($0, NSFont.systemFont(ofSize: 11))] } ?? [])
        {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = font
            label.isSelectable = false
            label.preferredMaxLayoutWidth = PanelGeometry.width - 2 * PanelGeometry.margin
            labels.append(label)
        }
        let buttons: [NSView] = ask.choices.enumerated().map { index, choice in
            let button = NSButton(title: choice, target: target, action: #selector(pick(_:)))
            button.tag = index
            button.refusesFirstResponder = true
            return button
        }
        let row = NSStackView(views: buttons)
        let column = NSStackView(views: labels + [row])
        column.orientation = .vertical
        column.alignment = .leading
        column.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        column.setFrameSize(column.fittingSize)
        made.setContentSize(column.fittingSize)
        made.contentView = column
        return made
    }
    @objc private func pick(_ sender: NSButton) {
        if let shown, shown.choices.indices.contains(sender.tag) {
            questions.answer(shown, choice: shown.choices[sender.tag])
        }
        draw()
    }
}
