// swift-tools-version: 6.0
import PackageDescription

// term-llm Computer Use: a Swift port of browser-use/macos-harness (MIT, see
// LICENSE-macos-harness), pinned at 43d9edf. docs/design/COMPUTER-USE.md.
//
// ComputerUseCore is pure Foundation (no AppKit, no side effects on the Mac) so
// its golden fixtures run under `swift test`. ComputerUseSystem holds the AX,
// event, capture and drawing code. ComputerUseHelper is the helper app's
// server and tool orchestration; ComputerUseClient is `term-llm-computer`.
// No target has resources: the command-line tool can't carry a bundle.
let package = Package(
    name: "ComputerUseKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ComputerUseCore", targets: ["ComputerUseCore"]),
        .library(name: "ComputerUseSystem", targets: ["ComputerUseSystem"]),
        .library(name: "ComputerUseHelper", targets: ["ComputerUseHelper"]),
        .library(name: "ComputerUseClient", targets: ["ComputerUseClient"]),
    ],
    targets: [
        .target(name: "ComputerUseCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "ComputerUseSystem", dependencies: ["ComputerUseCore"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "ComputerUseHelper", dependencies: ["ComputerUseCore", "ComputerUseSystem"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "ComputerUseClient", dependencies: ["ComputerUseCore"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "ComputerUseCoreTests", dependencies: ["ComputerUseCore"],
                    resources: [.copy("Fixtures")], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "ComputerUseSystemTests", dependencies: ["ComputerUseSystem"],
                    resources: [.copy("Fixtures")], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "ComputerUseHelperTests", dependencies: ["ComputerUseHelper"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "ComputerUseClientTests", dependencies: ["ComputerUseClient"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ],
    // All library and test targets are checked in Swift 6. Keep the explicit
    // settings as well as the default so regressions remain visible. See SWIFT6.md.
    swiftLanguageModes: [.v6]
)
