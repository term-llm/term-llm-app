import CryptoKit
import Foundation

/// Scene identity and short-lived attendance evidence are separate from a URL.
/// The page supplies attendance only after applying the shared presence policy.
@MainActor
final class PushWindowRegistry {
    nonisolated static func identifier(persistentIdentifier: String) -> String {
        "native_" + Data(SHA256.hash(data: Data(persistentIdentifier.utf8))).base64URLEncodedString()
    }

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
    var keyWindowOverride: (() -> String?)?
    var sceneIsActive: (String) -> Bool = { _ in false }

    private final class WeakScene {
        weak var value: NativeWindowScene?
        init(_ value: NativeWindowScene) { self.value = value }
    }

    func register(windowID: String, scene: NativeWindowScene) {
        scenes[windowID] = WeakScene(scene)
    }

    func scene(windowID: String) -> NativeWindowScene? { scenes[windowID]?.value }

    func keyWindowID() -> String? {
        if let keyWindowOverride { return keyWindowOverride() }
        let keys = scenes.filter { $0.value.value?.isForegroundActive == true &&
            $0.value.value?.hasKeyWindow == true }.map { $0.key }
        return keys.count == 1 ? keys.first : nil // ambiguous is not arbitrary
    }

    func existingWindowIDs() -> Set<String> {
        var ids = Set(scenes.compactMap { $0.value.value == nil ? nil : $0.key })
        if let key = keyWindowID() { ids.insert(key) }
        return ids
    }

    /// The only scene still attached to the app in any activation state (the
    /// key scene counts); nil when there is none yet or more than one.
    func soleWindowID() -> String? {
        var ids = Set(scenes.compactMap { id, scene in
            scene.value.flatMap { $0.isAttachedToApp ? id : nil }
        })
        if let key = keyWindowID() { ids.insert(key) }
        return ids.count == 1 ? ids.first : nil
    }

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
        return scenes[windowID]?.value?.isForegroundActive == true || sceneIsActive(windowID)
    }
}
