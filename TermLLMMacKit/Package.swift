// swift-tools-version: 6.0
import PackageDescription

// Platform-neutral companion logic for the native macOS target. Keeping this
// out of the app target lets macOS-only provisioning, service-contract and
// login-item behaviour run under `swift test` on a real Mac without a GUI.
let package = Package(
    name: "TermLLMMacKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TermLLMMacKit", targets: ["TermLLMMacKit"]),
    ],
    targets: [
        .target(name: "TermLLMMacKit"),
        .testTarget(name: "TermLLMMacKitTests", dependencies: ["TermLLMMacKit"]),
    ]
)
