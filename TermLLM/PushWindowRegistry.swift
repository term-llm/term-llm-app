import Foundation
import UIKit

/// Scene identity and short-lived attendance evidence are separate from a URL.
/// The page supplies attendance only after applying the shared presence policy.
@MainActor
final class PushWindowRegistry {
    struct Binding {
        var documentID: String
        var origin: String
        var sequence: Int64 = -1
        var active = false
        var expires = Date.distantPast
        var uptimeExpiry: TimeInterval = 0
    }

    private var bindings: [String: Binding] = [:]
    private var scenes: [String: WeakScene] = [:]
    var sceneIsActive: (String) -> Bool = { _ in false }

    private final class WeakScene {
        weak var value: UIWindowScene?
        init(_ value: UIWindowScene) { self.value = value }
    }

    func register(windowID: String, scene: UIWindowScene) {
        scenes[windowID] = WeakScene(scene)
    }

    func scene(windowID: String) -> UIWindowScene? { scenes[windowID]?.value }

    func bind(windowID: String, documentID: String, origin: String) {
        if bindings[windowID]?.documentID == documentID { return }
        bindings[windowID] = Binding(documentID: documentID, origin: origin)
    }

    func invalidate(windowID: String) { bindings.removeValue(forKey: windowID) }

    func release(windowID: String) { bindings[windowID]?.active = false }

    func update(windowID: String, documentID: String, origin: String, sequence: Int64,
                active: Bool, expires: Date, now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard var binding = bindings[windowID], binding.documentID == documentID, binding.origin == origin,
              sequence > binding.sequence, expires > now, expires.timeIntervalSince(now) <= 65 else { return false }
        binding.sequence = sequence
        binding.active = active
        binding.expires = expires
        binding.uptimeExpiry = uptime + expires.timeIntervalSince(now)
        bindings[windowID] = binding
        return true
    }

    func isAround(windowID: String, origin: String, now: Date = Date(),
                  uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let binding = bindings[windowID], binding.origin == origin, binding.active,
              binding.expires > now, binding.uptimeExpiry > uptime else { return false }
        // A recent page heartbeat does not keep a backgrounded scene attended.
        return scenes[windowID]?.value?.activationState == .foregroundActive || sceneIsActive(windowID)
    }
}
