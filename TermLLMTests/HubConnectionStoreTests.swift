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
    func testDiscoveryNetworkFailurePreservesCatalogAndSurfacesSafeDiagnostic() async throws {
        let defaults = defaults()
        let store = HubConnectionStore(defaults: defaults)
        let original = try store.save(name: "Original", kind: .hub, address: "https://example.com/")
        let raw = defaults.data(forKey: HubConnectionStore.storageKey)
        let failure = HubServerRole.DiscoveryFailure.network(code: URLError.cannotFindHost.rawValue, tailnet: true)
        for id in [nil, Optional(original.id)] {
            do {
                try await store.saveDetectingKind(id: id, name: "Tailnet", address: "https://desk.tail123.ts.net/") { _ in
                    throw failure
                }
                XCTFail("Failed discovery must not save")
            } catch {
                XCTAssertEqual(error as? HubServerRole.DiscoveryFailure, failure)
                XCTAssertTrue(error.localizedDescription.contains("MagicDNS"))
            }
            XCTAssertEqual(store.connections, [original])
            XCTAssertEqual(store.selectedID, original.id)
            XCTAssertEqual(defaults.data(forKey: HubConnectionStore.storageKey), raw)
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

    func testManagedLocalServiceValidatorAllowsOnlyExactLoopbackHTTP() {
        for (raw, canonical) in [
            ("http://127.0.0.1:8737", "http://127.0.0.1:8737/"),
            ("http://localhost:8737/", "http://localhost:8737/"),
            ("HTTP://LOCALHOST:8737/mount", "http://localhost:8737/mount/"),
            ("http://127.0.0.1:8737/mount/", "http://127.0.0.1:8737/mount/")
        ] {
            XCTAssertEqual(HubConnectionStore.canonicalManagedLocalServiceURL(raw)?.absoluteString, canonical, raw)
        }
        for raw in ["https://127.0.0.1:8737/", "http://example.com:8737/", "http://localhost.evil.com:8737/",
                    "http://127.0.0.2:8737/", "http://0.0.0.0:8737/", "http://[::1]:8737/",
                    "http://127.0.0.1/", "http://127.0.0.1:0/", "http://127.0.0.1:65536/",
                    "http://u:p@127.0.0.1:8737/", "http://127.0.0.1:8737/?token=secret",
                    "http://127.0.0.1:8737/#fragment", "http://127.0.0.1:8737/a/../b",
                    "http://127.0.0.1:8737/a//b", "http://127.0.0.1:8737/%2e%2e/",
                    "http://127.0.0.1:8737/%252f", "http://127.0.0.1:8737/a\\b"] {
            XCTAssertNil(HubConnectionStore.canonicalManagedLocalServiceURL(raw), raw)
        }
        // Ordinary saved connections keep the HTTPS policy; the local exception is not general.
        XCTAssertNil(HubConnectionStore.canonicalURL("http://127.0.0.1:8737/"))
        XCTAssertNotNil(HubConnectionStore.canonicalURL("https://example.com/"))
    }

    func testManagedLocalServiceFlagIsOnlyModelMetadata() {
        let url = URL(string: "http://127.0.0.1:8737/")!
        XCTAssertFalse(HubConnection(id: UUID(), name: "Mac", kind: .directNode, url: url).isManagedLocalService)
        XCTAssertFalse(HubConnection(id: UUID(), name: "Mac", kind: .directNode, url: url,
                                     managedLocalService: false).isManagedLocalService)
        let managed = HubConnection(id: UUID(), name: "Mac", kind: .directNode, url: url,
                                    managedLocalService: true)
        XCTAssertTrue(managed.isManagedLocalService)
        XCTAssertFalse(managed.isLinkedDevices, "The local-service flag never implies a linked peer identity")
    }

    #if !os(macOS)
    func testManagedLocalFlagIsRejectedOutsideTheMacBuild() throws {
        let url = URL(string: "http://127.0.0.1:8737/")!
        let ordinary = HubConnection(id: UUID(), name: "Work", kind: .hub,
                                     url: URL(string: "https://example.com/")!)
        let good = try JSONEncoder().encode(HubConnectionStore.Document(connections: [ordinary], selectedID: ordinary.id))
        XCTAssertEqual(try HubConnectionStore.validatedDocument(good).connections, [ordinary])

        let flagged = HubConnection(id: UUID(), name: "This Mac", kind: .directNode, url: url,
                                    managedLocalService: true)
        let raw = try JSONEncoder().encode(HubConnectionStore.Document(connections: [flagged], selectedID: flagged.id))
        XCTAssertThrowsError(try HubConnectionStore.validatedDocument(raw)) {
            XCTAssertEqual($0 as? HubConnectionStore.ValidationError, .corrupt)
        }
        let defaults = defaults()
        defaults.set(raw, forKey: HubConnectionStore.storageKey)
        let store = HubConnectionStore(defaults: defaults)
        XCTAssertTrue(store.connections.isEmpty)
        XCTAssertNotNil(store.persistenceError)
        XCTAssertEqual(defaults.data(forKey: HubConnectionStore.storageKey), raw,
                       "The unreadable catalog must be preserved, not rewritten")
        XCTAssertNil(ServerAddress.browserURL(url.absoluteString, selectedConnection: flagged),
                     "Only the Mac build can use the managed local HTTP exception")
    }
    #endif

    #if os(macOS)
    func testManagedLocalServiceCatalogRoundTripAndIdentity() throws {
        let defaults = defaults()
        let store = HubConnectionStore(defaults: defaults)
        let saved = try store.saveManagedLocalService(address: "http://127.0.0.1:8737")
        XCTAssertEqual(saved.url.absoluteString, "http://127.0.0.1:8737/")
        XCTAssertEqual(saved.kind, .directNode)
        XCTAssertTrue(saved.isManagedLocalService)
        XCTAssertEqual(store.selectedID, saved.id)

        // The same canonical endpoint is the same trust identity, not a duplicate.
        XCTAssertEqual(try store.saveManagedLocalService(address: "http://127.0.0.1:8737/").id, saved.id)
        XCTAssertEqual(store.connections, [saved])
        let other = try store.saveManagedLocalService(address: "http://127.0.0.1:9000/")
        XCTAssertNotEqual(other.id, saved.id)
        XCTAssertTrue(other.isManagedLocalService)

        let object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: XCTUnwrap(defaults.data(forKey: HubConnectionStore.storageKey))) as? [String: Any])
        let records = try XCTUnwrap(object["connections"] as? [[String: Any]])
        XCTAssertEqual(Set(records[0].keys), ["id", "name", "kind", "url", "managedLocalService"],
                       "Persist only the metadata flag, never a credential")
        XCTAssertEqual((records[0]["managedLocalService"] as? NSNumber)?.boolValue, true)

        let reloaded = HubConnectionStore(defaults: defaults)
        XCTAssertNil(reloaded.persistenceError)
        XCTAssertEqual(reloaded.connections, store.connections)
        XCTAssertEqual(reloaded.selectedID, saved.id)
    }

    /// A running local service joins the app as This Mac without typing an
    /// address; removing it is respected until the user opens local chat again.
    func testBackgroundInclusionAddsThisMacOnceAndRespectsRemoval() throws {
        let store = HubConnectionStore(defaults: defaults())
        let added = try XCTUnwrap(store.attachManagedLocalService(address: "http://127.0.0.1:8737/ui/"))
        XCTAssertEqual(added.name, "This Mac")
        XCTAssertTrue(added.isManagedLocalService)
        XCTAssertEqual(store.selectedID, added.id)
        XCTAssertEqual(try store.attachManagedLocalService(address: "http://127.0.0.1:8737/ui/")?.id, added.id)
        XCTAssertEqual(store.connections.count, 1)

        store.remove(added.id)
        XCTAssertTrue(store.localServiceDeclined)
        XCTAssertNil(try store.attachManagedLocalService(address: "http://127.0.0.1:8737/ui/"),
                     "A removed This Mac must not come back on its own")
        XCTAssertTrue(store.connections.isEmpty)

        let reopened = try store.saveManagedLocalService(address: "http://127.0.0.1:8737/ui/")
        XCTAssertFalse(store.localServiceDeclined, "Opening local chat again re-enables inclusion")
        XCTAssertEqual(try store.attachManagedLocalService(address: "http://127.0.0.1:8737/ui/")?.id, reopened.id)
    }

    func testBackgroundInclusionMovesThisMacToANewPortWithoutADuplicate() throws {
        let store = HubConnectionStore(defaults: defaults())
        let remote = try store.save(name: "Work", kind: .hub, address: "https://example.com/")
        let old = try XCTUnwrap(store.attachManagedLocalService(address: "http://127.0.0.1:8737/"))
        store.select(old.id)
        let moved = try XCTUnwrap(store.attachManagedLocalService(address: "http://127.0.0.1:9000/"))
        XCTAssertNotEqual(moved.id, old.id)
        XCTAssertEqual(store.connections.filter(\.isManagedLocalService), [moved])
        XCTAssertEqual(store.selectedID, moved.id, "A selected This Mac stays selected after it moves")
        XCTAssertTrue(store.connections.contains(remote))
        XCTAssertFalse(store.localServiceDeclined, "Moving isn't the user removing it")
        XCTAssertThrowsError(try store.attachManagedLocalService(address: "https://example.com/"))
    }

    func testManagedLocalFlagRejectsLinkedAndNonNodeSources() throws {
        let url = URL(string: "http://127.0.0.1:8737/")!
        let key = LinkedDevicesBase64URL.encode(Data(repeating: 1, count: 32))
        let valid = HubConnection(id: UUID(), name: "This Mac", kind: .directNode, url: url,
                                  managedLocalService: true)
        let doc = try HubConnectionStore.validatedDocument(
            try JSONEncoder().encode(HubConnectionStore.Document(connections: [valid], selectedID: valid.id)))
        XCTAssertEqual(doc.connections.first?.url.absoluteString, "http://127.0.0.1:8737/")
        XCTAssertTrue(try XCTUnwrap(doc.connections.first).isManagedLocalService)

        let invalid = [
            HubConnection(id: UUID(), name: "This Mac", kind: .hub, url: url, managedLocalService: true),
            HubConnection(id: UUID(), name: "This Mac", kind: .directNode, url: url,
                          linkedDevicesHostKey: key, managedLocalService: true),
            HubConnection(id: UUID(), name: "This Mac", kind: .directNode,
                          url: URL(string: "https://127.0.0.1:8737/")!, managedLocalService: true),
            HubConnection(id: UUID(), name: "This Mac", kind: .directNode,
                          url: URL(string: "http://example.com:8737/")!, managedLocalService: true)
        ]
        for source in invalid {
            let raw = try JSONEncoder().encode(HubConnectionStore.Document(connections: [source],
                                                                           selectedID: source.id))
            XCTAssertThrowsError(try HubConnectionStore.validatedDocument(raw), source.url.absoluteString) {
                XCTAssertEqual($0 as? HubConnectionStore.ValidationError, .corrupt)
            }
        }
    }

    func testManagedLocalSaveCannotBorrowAnotherSourcesEndpoint() throws {
        let store = HubConnectionStore(defaults: defaults())
        let linked = try store.saveLinkedDevices(id: UUID(), name: "Phone",
                                                 hostKey: Data(repeating: 2, count: 32), bridgePort: 8737)
        XCTAssertThrowsError(try store.saveManagedLocalService(address: linked.url.absoluteString)) {
            XCTAssertEqual($0 as? HubConnectionStore.ValidationError, .duplicate)
        }
        XCTAssertEqual(store.connections, [linked])
        XCTAssertFalse(try XCTUnwrap(store.connections.first).isManagedLocalService)
        XCTAssertTrue(try XCTUnwrap(store.connections.first).isLinkedDevices)
    }

    func testManagedLocalLabelEditKeepsTrustButEndpointMoveRotatesIdentity() async throws {
        let store = HubConnectionStore(defaults: defaults())
        let managed = try store.saveManagedLocalService(address: "http://127.0.0.1:8737/")
        let renamed = try await store.saveDetectingKind(id: managed.id, name: "Local",
                                                        address: managed.url.absoluteString) { _ in
            XCTFail("A label-only edit of a managed source must not rediscover it")
            return .unknown
        }
        XCTAssertEqual(renamed.id, managed.id)
        XCTAssertEqual(renamed.kind, .directNode)
        XCTAssertTrue(renamed.isManagedLocalService)
        XCTAssertEqual(store.connections, [renamed])

        // The HTTP exception is the exact saved spelling, not a general loopback grant.
        do {
            _ = try await store.saveDetectingKind(id: managed.id, name: "Local",
                                                  address: "http://127.0.0.1:8737") { _ in .unknown }
            XCTFail("Only the exact saved managed URL may skip ordinary validation")
        } catch {
            XCTAssertEqual(error as? HubConnectionStore.ValidationError, .invalid)
        }

        let moved = try await store.saveDetectingKind(id: managed.id, name: "Moved",
                                                      address: "https://example.com/") { _ in .direct }
        XCTAssertNotEqual(moved.id, managed.id, "A new endpoint is a new trust realm")
        XCTAssertFalse(moved.isManagedLocalService)
        XCTAssertEqual(moved.url.absoluteString, "https://example.com/")
        XCTAssertEqual(store.selectedID, moved.id)
    }

    func testManagedLocalBrowserEntryPointRequiresTheExactOwnedBaseURL() throws {
        let store = HubConnectionStore(defaults: defaults())
        let managed = try store.saveManagedLocalService(address: "http://127.0.0.1:8737/")
        XCTAssertEqual(ServerAddress.browserURL("http://127.0.0.1:8737", selectedConnection: managed),
                       managed.url)
        for other in ["http://127.0.0.1:8738/", "http://127.0.0.1:8737/other/",
                      "http://localhost:8737/", "https://127.0.0.1:8737/",
                      "http://u:p@127.0.0.1:8737/", "http://127.0.0.1:8737/?token=secret"] {
            XCTAssertNil(ServerAddress.browserURL(other, selectedConnection: managed), other)
        }
        // Catalyst is not the simulator: ordinary HTTP input stays rejected.
        XCTAssertNil(ServerAddress.parse("http://localhost:8737/"))
        XCTAssertNil(ServerAddress.browserURL("http://localhost:8737/", selectedConnection: nil))
        XCTAssertNotNil(ServerAddress.parse("https://example.com/"))
    }
    #endif
}
