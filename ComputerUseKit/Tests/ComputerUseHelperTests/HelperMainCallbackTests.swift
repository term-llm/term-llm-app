import ComputerUseCore
import Darwin
import Foundation
import XCTest

@testable import ComputerUseHelper

final class HelperMainCallbackTests: XCTestCase {
    /// Construct on MainActor, exactly as HelperMain.run does, but let Dispatch
    /// invoke the callback on its real worker queue. An inherited actor check
    /// would crash the test process instead of reaching onMaintenance.
    @MainActor
    func testMaintenanceTimerRunsOffMainActor() async throws {
        let home = URL(fileURLWithPath: "/tmp/cu-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: home) }
        let ticked = expectation(description: "background maintenance")
        ticked.assertForOverFulfill = false
        var configuration = HelperConfiguration(environment: [
            "TERM_LLM_COMPUTER_HOME": home.path,
            "TERM_LLM_COMPUTER_SOCKET": home.appendingPathComponent("helper.sock").path,
            "TERM_LLM_COMPUTER_HOST_PID": String(getpid()),
        ])
        configuration.onMaintenance = {
            XCTAssertFalse(Thread.isMainThread)
            ticked.fulfill()
        }
        let server = HelperServer(configuration: configuration)
        defer { server.stop() }
        try server.start()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.setEventHandler(handler: HelperMain.maintenanceHandler(server: server, configuration: configuration))
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.resume()
        defer { timer.cancel() }
        await fulfillment(of: [ticked], timeout: 3)
    }

    @MainActor
    func testShutdownHandlerRunsOffMainActor() async throws {
        let home = URL(fileURLWithPath: "/tmp/cu-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: home) }
        let stopped = expectation(description: "background shutdown")
        let configuration = HelperConfiguration(environment: [
            "TERM_LLM_COMPUTER_HOME": home.path,
            "TERM_LLM_COMPUTER_SOCKET": home.appendingPathComponent("helper.sock").path,
        ])
        let server = HelperServer(configuration: configuration)
        server.onShutdown = { stopped.fulfill() }
        defer { server.stop() }
        try server.start()
        // Exercise the signal handler without changing process-wide signal
        // disposition in XCTest. Both dispatch sources invoke the same callback.
        let source = DispatchSource.makeUserDataAddSource(queue: .global())
        source.setEventHandler(handler: HelperMain.shutdownHandler(server: server))
        source.resume()
        defer { source.cancel() }
        source.add(data: 1)
        await fulfillment(of: [stopped], timeout: 3)
    }
}
