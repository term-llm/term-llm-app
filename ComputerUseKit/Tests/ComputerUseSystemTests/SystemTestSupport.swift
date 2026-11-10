import AppKit
import ComputerUseCore
import XCTest
@testable import ComputerUseSystem

func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cu-system-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
func assertHarnessError(_ suffix: String? = nil, name: String? = nil, file: StaticString = #filePath, line: UInt = #line, _ work: () throws -> Void) {
    XCTAssertThrowsError(try work(), file: file, line: line) { error in
        guard let error = error as? HarnessError else { return XCTFail("Not a HarnessError: \(error)", file: file, line: line) }
        if let suffix { XCTAssertTrue(error.message.hasSuffix(suffix), error.message, file: file, line: line) }
        if let name { XCTAssertEqual(error.name, name, file: file, line: line) }
    }
}
func fakeImage(_ width: Int = 64, _ height: Int = 48) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}
func fixtureWindow(frame: CGRect = CGRect(x: 60, y: 58, width: 32, height: 24)) -> ComputerUseCore.WindowRef {
    ComputerUseCore.WindowRef(element: UIElementRef(NSObject()), windowID: 7, pid: 77, title: "Fixture", frame: frame)
}
