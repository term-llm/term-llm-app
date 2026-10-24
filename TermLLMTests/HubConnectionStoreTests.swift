import XCTest
@testable import TermLLM

@MainActor
final class HubConnectionStoreTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "phoneHub.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
    func testEmptyHomeCatalogNeedsNoServer() {
        let defaults = defaults()
        let store = HubConnectionStore(defaults: defaults)
        XCTAssertTrue(store.connections.isEmpty)
        XCTAssertNil(store.selectedID)
        XCTAssertEqual(defaults.string(forKey: "serverURL"), "")
    }
    func testLegacyMigrationIsIdempotentAndDoesNotGuessAuthFailure() async throws {
        let defaults = defaults()
        defaults.set("https://example.com/mount", forKey: "serverURL")
        let store = HubConnectionStore(defaults: defaults)
        let source = try XCTUnwrap(store.connections.first)
        XCTAssertEqual(source.needsKindReview, true)
        await store.resolveLegacyKinds { _ in .unknown }
        XCTAssertEqual(store.connections.first?.needsKindReview, true)
        let again = HubConnectionStore(defaults: defaults)
        XCTAssertEqual(again.connections.map(\.id), [source.id])
        XCTAssertEqual(defaults.string(forKey: "serverURL"), "https://example.com/mount/")
    }
    func testLegacyHubAndDirectAreResolvedWithoutReplacingIdentity() async throws {
        for (role, kind) in [(HubServerRole.hub, HubConnection.Kind.hub), (.direct, .directNode)] {
            let defaults = defaults()
            defaults.set("https://example.com/mount/", forKey: "serverURL")
            let store = HubConnectionStore(defaults: defaults)
            let id = try XCTUnwrap(store.selectedID)
            await store.resolveLegacyKinds { _ in role }
            XCTAssertEqual(store.selected?.kind, kind)
            XCTAssertNil(store.selected?.needsKindReview)
            XCTAssertEqual(store.selectedID, id)
            XCTAssertEqual(HubConnectionStore(defaults: defaults).selectedID, id)
        }
    }
    func testAutomaticDetectionSavesHubAndDirectAtTheirMounts() async throws {
        for (role, kind) in [(HubServerRole.hub, HubConnection.Kind.hub), (.direct, .directNode)] {
            let store = HubConnectionStore(defaults: defaults())
            let source = try await store.saveDetectingKind(name: "Server", address: "https://example.com/mount") { url in
                XCTAssertEqual(url.absoluteString, "https://example.com/mount/")
                return role
            }
            XCTAssertEqual(source.kind, kind)
            XCTAssertNil(source.needsKindReview)
            XCTAssertEqual(store.selected, source)
        }
    }
    func testFailedDetectionDoesNotSaveOrReplaceExistingConnection() async throws {
        let store = HubConnectionStore(defaults: defaults())
        let original = try store.save(name: "Original", kind: .hub, address: "https://example.com/")
        for id in [nil, Optional(original.id)] {
            do {
                try await store.saveDetectingKind(id: id, name: "New", address: "https://new.example/") { _ in .unknown }
                XCTFail("Unknown roles must not be guessed")
            } catch {
                XCTAssertEqual(error as? HubConnectionStore.ValidationError, .discoveryFailed)
            }
            XCTAssertEqual(store.connections, [original])
        }
    }
    func testCancelledDetectionDoesNotSave() async throws {
        let store = HubConnectionStore(defaults: defaults())
        let task = Task {
            try await store.saveDetectingKind(name: "Server", address: "https://example.com/") { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return .hub
            }
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled discovery must not save")
        } catch is CancellationError {
            XCTAssertTrue(store.connections.isEmpty)
        }
    }
    func testAutomaticNameEditDoesNotRequireDiscovery() async throws {
        let store = HubConnectionStore(defaults: defaults())
        let original = try store.save(name: "Original", kind: .directNode, address: "https://example.com/")
        let renamed = try await store.saveDetectingKind(id: original.id, name: "Renamed", address: original.url.absoluteString) { _ in
            XCTFail("Verified unchanged endpoints do not need discovery")
            return .unknown
        }
        XCTAssertEqual(renamed.id, original.id)
        XCTAssertEqual(renamed.kind, .directNode)
    }
    func testAutomaticEndpointChangeRotatesIdentity() async throws {
        let store = HubConnectionStore(defaults: defaults())
        let original = try store.save(name: "Original", kind: .hub, address: "https://example.com/")
        let moved = try await store.saveDetectingKind(id: original.id, name: "Moved", address: "https://new.example/") { _ in .direct }
        XCTAssertNotEqual(moved.id, original.id)
        XCTAssertEqual(moved.kind, .directNode)
    }
    func testDetectionCannotResurrectRemovedConnection() async throws {
        let store = HubConnectionStore(defaults: defaults())
        let original = try store.save(name: "Original", kind: .hub, address: "https://example.com/")
        do {
            try await store.saveDetectingKind(id: original.id, name: "Moved", address: "https://new.example/") { _ in
                store.remove(original.id)
                return .direct
            }
            XCTFail("Removed connection must not be saved")
        } catch {
            XCTAssertEqual(error as? HubConnectionStore.ValidationError, .missing)
        }
        XCTAssertTrue(store.connections.isEmpty)
    }
    func testSaveSelectRemovePersistenceAndNoSecretsInDefaults() throws {
        let defaults = defaults()
        let store = HubConnectionStore(defaults: defaults)
        let a = try store.save(name: "Work", kind: .hub, address: "https://example.com/work")
        let b = try store.save(name: "Laptop", kind: .directNode, address: "https://example.com/direct/")
        store.select(b.id)
        let loaded = HubConnectionStore(defaults: defaults)
        XCTAssertEqual(loaded.connections, [a, b])
        XCTAssertEqual(loaded.selectedID, b.id)
        XCTAssertEqual(defaults.string(forKey: "serverURL"), b.url.absoluteString)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: HubConnectionStore.storageKey))) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["connections", "selectedID"])
        let records = try XCTUnwrap(object["connections"] as? [[String: Any]])
        XCTAssertEqual(Set(records[0].keys), ["id", "name", "kind", "url"])
        loaded.remove(b.id)
        XCTAssertEqual(loaded.selectedID, a.id)
        XCTAssertEqual(defaults.string(forKey: "serverURL"), a.url.absoluteString)
        loaded.remove(a.id)
        XCTAssertEqual(defaults.string(forKey: "serverURL"), "")
    }
    func testNameEditKeepsIdentityButTrustRealmEditRotatesIdentity() throws {
        let store = HubConnectionStore(defaults: defaults())
        let a = try store.save(name: "Work", kind: .hub, address: "https://example.com/work/")
        let renamed = try store.save(id: a.id, name: "Renamed", kind: .hub, address: a.url.absoluteString)
        XCTAssertEqual(renamed.id, a.id)
        let moved = try store.save(id: a.id, name: "Moved", kind: .hub, address: "https://example.com/other/")
        XCTAssertNotEqual(moved.id, a.id)
        XCTAssertEqual(store.selectedID, moved.id)
        let changedKind = try store.save(id: moved.id, name: "Node", kind: .directNode, address: moved.url.absoluteString)
        XCTAssertNotEqual(changedKind.id, moved.id)
        XCTAssertEqual(store.selectedID, changedKind.id)
    }
    func testDuplicateCanonicalEndpointIsRejectedAcrossKinds() throws {
        let store = HubConnectionStore(defaults: defaults())
        _ = try store.save(name: "Work", kind: .hub, address: "https://EXAMPLE.com:443/work")
        XCTAssertThrowsError(try store.save(name: "Duplicate", kind: .directNode, address: "https://example.com/work/"))
        _ = try store.save(name: "Sibling", kind: .directNode, address: "https://example.com/work/child/")
        XCTAssertEqual(store.connections.count, 2, "Separate UUID WK stores isolate overlapping mounts")
    }
    func testValidationRejectsSecretsAndAmbiguousPaths() {
        for raw in ["http://example.com/", "https://u:p@example.com/", "https://example.com/?token=secret",
                    "https://example.com/#secret", "https://example.com/a/../b", "https://example.com/a//b",
                    "https://example.com/%2e%2e/", "https://example.com/%252f", "https://example.com/a\\b"] {
            XCTAssertNil(HubConnectionStore.canonicalURL(raw), raw)
        }
    }
    func testCorruptCatalogIsPreservedUntilExplicitResetAndNeverRemigratesLegacy() throws {
        let defaults = defaults()
        let raw = Data("not json".utf8)
        defaults.set(raw, forKey: HubConnectionStore.storageKey)
        defaults.set("https://legacy.example/", forKey: "serverURL")
        let store = HubConnectionStore(defaults: defaults)
        XCTAssertNotNil(store.persistenceError)
        XCTAssertTrue(store.connections.isEmpty)
        XCTAssertEqual(defaults.data(forKey: HubConnectionStore.storageKey), raw)
        XCTAssertThrowsError(try store.save(name: "New", kind: .hub, address: "https://new.example/"))
        XCTAssertEqual(defaults.string(forKey: "serverURL"), "https://legacy.example/")
        store.resetUnreadableCatalog()
        XCTAssertNil(store.persistenceError)
        XCTAssertTrue(HubConnectionStore(defaults: defaults).connections.isEmpty)
    }
    func testDuplicateUUIDCatalogIsRejectedWithoutOverwrite() throws {
        let defaults = defaults()
        let id = UUID()
        let records = [HubConnection(id: id, name: "A", kind: .hub, url: URL(string: "https://a.example/")!),
                       HubConnection(id: id, name: "B", kind: .hub, url: URL(string: "https://b.example/")!)]
        let json: [String: Any] = ["connections": try JSONSerialization.jsonObject(with: JSONEncoder().encode(records)), "selectedID": id.uuidString]
        let raw = try JSONSerialization.data(withJSONObject: json)
        defaults.set(raw, forKey: HubConnectionStore.storageKey)
        XCTAssertNotNil(HubConnectionStore(defaults: defaults).persistenceError)
        XCTAssertEqual(defaults.data(forKey: HubConnectionStore.storageKey), raw)
    }
    func testEditedOrRemovedLegacyProbeCannotOverwriteNewIdentity() async throws {
        let defaults = defaults()
        defaults.set("https://legacy.example/", forKey: "serverURL")
        let store = HubConnectionStore(defaults: defaults)
        let old = try XCTUnwrap(store.selected)
        await store.resolveLegacyKinds { _ in
            _ = try? store.save(id: old.id, name: "Explicit", kind: .hub, address: "https://new.example/")
            return .direct
        }
        XCTAssertEqual(store.selected?.kind, .hub)
        XCTAssertNotEqual(store.selectedID, old.id)
    }
}
