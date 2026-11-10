// swift-tools-version: 5.9
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
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ComputerUseCore", targets: ["ComputerUseCore"]),
        .library(name: "ComputerUseSystem", targets: ["ComputerUseSystem"]),
        .library(name: "ComputerUseHelper", targets: ["ComputerUseHelper"]),
        .library(name: "ComputerUseClient", targets: ["ComputerUseClient"]),
    ],
    targets: [
        .target(name: "ComputerUseCore"),
        .target(name: "ComputerUseSystem", dependencies: ["ComputerUseCore"]),
        .target(name: "ComputerUseHelper", dependencies: ["ComputerUseCore", "ComputerUseSystem"]),
        .target(name: "ComputerUseClient", dependencies: ["ComputerUseCore"]),
        .testTarget(name: "ComputerUseCoreTests", dependencies: ["ComputerUseCore"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "ComputerUseHelperTests", dependencies: ["ComputerUseHelper"]),
    ]
)
