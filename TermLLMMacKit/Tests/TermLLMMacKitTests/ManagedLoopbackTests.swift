import XCTest
@testable import TermLLMMacKit

final class ManagedLoopbackTests: XCTestCase {
    private func status(url: String?, host: String = "127.0.0.1", port: Int = 8765,
                        basePath: String = "/", installed: Bool = true,
                        managed: Bool = true) -> ServiceStatus {
        ServiceStatus(kind: "web", installed: installed, managed: managed, registered: true,
                      state: .ready, running: true, autostart: false, url: url,
                      host: host, port: port, basePath: basePath, auth: "bearer")
    }

    func testAcceptsOwnedLoopbackOrigin() throws {
        let endpoint = try ManagedLoopbackEndpoint.make(from: status(url: "http://127.0.0.1:8765/")).get()
        XCTAssertEqual(endpoint.baseURL.absoluteString, "http://127.0.0.1:8765/")
        XCTAssertTrue(endpoint.allows(try XCTUnwrap(URL(string: "http://127.0.0.1:8765/chat/1"))))
        XCTAssertTrue(endpoint.allows(try XCTUnwrap(URL(string: "http://127.0.0.1:8765/?session=1"))))
    }

    func testRejectsRemoteHostAndHTTPSDowngrade() {
        if case .failure(.notLoopback) = ManagedLoopbackEndpoint.make(from: status(url: "http://example.com:8765/")) {
        } else {
            XCTFail("remote host must be rejected")
        }
        if case .failure(.notHTTP) = ManagedLoopbackEndpoint.make(from: status(url: "https://127.0.0.1:8765/")) {
        } else {
            XCTFail("non-HTTP managed endpoint must be rejected")
        }
    }

    func testRejectsUnmanagedAndUninstalledServices() {
        if case .failure(.unmanaged) = ManagedLoopbackEndpoint.make(from: status(url: "http://127.0.0.1:8765/", managed: false)) {
        } else {
            XCTFail("unmanaged service must be rejected")
        }
        if case .failure(.notInstalled) = ManagedLoopbackEndpoint.make(from: status(url: "http://127.0.0.1:8765/", installed: false)) {
        } else {
            XCTFail("uninstalled service must be rejected")
        }
    }

    func testRejectsPortMismatchAndCredentials() {
        if case .failure(.invalidURL) = ManagedLoopbackEndpoint.make(from: status(url: "http://127.0.0.1:9999/", port: 8765)) {
        } else {
            XCTFail("mismatched port must be rejected")
        }
        if case .failure(.invalidURL) = ManagedLoopbackEndpoint.make(from: status(url: "http://user:pass@127.0.0.1:8765/")) {
        } else {
            XCTFail("embedded credentials must be rejected")
        }
    }

    func testBasePathIsScoped() throws {
        let endpoint = try ManagedLoopbackEndpoint.make(from: status(url: "http://127.0.0.1:8765/term/",
                                                                    basePath: "/term/")).get()
        XCTAssertTrue(endpoint.allows(try XCTUnwrap(URL(string: "http://127.0.0.1:8765/term/chat"))))
        XCTAssertTrue(endpoint.allows(try XCTUnwrap(URL(string: "http://127.0.0.1:8765/term"))))
        XCTAssertFalse(endpoint.allows(try XCTUnwrap(URL(string: "http://127.0.0.1:8765/other"))))
        XCTAssertFalse(endpoint.allows(try XCTUnwrap(URL(string: "http://127.0.0.1:9000/term/chat"))))
    }

    func testHostAliasIsNotSilentlyAccepted() throws {
        let endpoint = try ManagedLoopbackEndpoint.make(from: status(url: "http://localhost:8765/")).get()
        XCTAssertTrue(endpoint.allows(try XCTUnwrap(URL(string: "http://localhost:8765/chat"))))
        XCTAssertFalse(endpoint.allows(try XCTUnwrap(URL(string: "http://127.0.0.1:8765/chat"))))
    }
}
