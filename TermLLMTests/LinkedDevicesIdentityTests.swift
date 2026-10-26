import CryptoKit
import XCTest
@testable import TermLLM

final class LinkedDevicesIdentityTests: XCTestCase {
    func testStrictBase64URLRejectsPaddingAlphabetAndNonCanonicalBits() {
        let bytes = Data((0..<32).map(UInt8.init))
        let encoded = LinkedDevicesBase64URL.encode(bytes)
        XCTAssertEqual(LinkedDevicesBase64URL.decode(encoded), bytes)
        XCTAssertNil(LinkedDevicesBase64URL.decode(encoded + "="))
        XCTAssertNil(LinkedDevicesBase64URL.decode("a+b"))
        XCTAssertNil(LinkedDevicesBase64URL.decode("AB")) // non-canonical trailing bits
        XCTAssertNil(LinkedDevicesBase64URL.decode(String(repeating: "A", count: 9000)))
    }

    func testIdentityIsPersistedPerHostBeforeGrantAndNeverShared() throws {
        let storage = LinkedDevicesMemoryStorage()
        let firstStore = LinkedDevicesIdentityStore(storage: storage)
        let hostA = Data(repeating: 1, count: 32)
        let hostB = Data(repeating: 2, count: 32)

        let a = try firstStore.prepare(hostKey: hostA)
        XCTAssertNil(a.reconnectCapability)
        XCTAssertEqual(a.deviceSeed.count, 32)
        XCTAssertEqual(a.devicePublicKey.count, 32)
        XCTAssertEqual(try firstStore.prepare(hostKey: hostA), a)

        let b = try firstStore.prepare(hostKey: hostB)
        XCTAssertNotEqual(a.deviceSeed, b.deviceSeed)
        XCTAssertNotEqual(a.devicePublicKey, b.devicePublicKey)

        // Relaunch uses the persisted key, not an in-memory fallback.
        let relaunched = LinkedDevicesIdentityStore(storage: storage)
        XCTAssertEqual(try relaunched.load(hostKey: hostA), a)
    }

    func testGrantRoundTripAndRemoval() throws {
        let storage = LinkedDevicesMemoryStorage()
        let store = LinkedDevicesIdentityStore(storage: storage)
        let host = Data(repeating: 3, count: 32)
        var credential = try store.prepare(hostKey: host)
        credential.deviceID = "device-1"
        credential.reconnectCapability = Data(repeating: 4, count: 32)
        credential.brokerURL = try XCTUnwrap(URL(string: "https://broker.example/"))
        credential.basePath = "/chat/"
        credential.scope = "web-v1"
        credential.hostLabel = "Sam's Mac"
        credential.pairedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try store.save(credential)
        XCTAssertEqual(try store.load(hostKey: host), credential)

        try store.remove(hostKey: host)
        XCTAssertThrowsError(try store.load(hostKey: host)) { error in
            XCTAssertEqual(error as? LinkedDevicesStorageError, .missing)
        }
    }

    func testCorruptStoredIdentityFailsClosed() throws {
        let storage = LinkedDevicesMemoryStorage()
        let host = Data(repeating: 5, count: 32)
        try storage.write(Data("{}".utf8), account: LinkedDevicesIdentityStore.account(hostKey: host))
        let store = LinkedDevicesIdentityStore(storage: storage)
        XCTAssertThrowsError(try store.prepare(hostKey: host)) { error in
            XCTAssertEqual(error as? LinkedDevicesStorageError, .corrupt)
        }
    }
}
