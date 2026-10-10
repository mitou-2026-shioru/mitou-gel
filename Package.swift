// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HapticCore",
    platforms: [.macOS(.v13), .iOS(.v17), .watchOS(.v10)],
    products: [.library(name: "HapticCore", targets: ["HapticCore"])],
    targets: [
        .target(name: "HapticCore", path: "Core"),
        .testTarget(name: "HapticCoreTests", dependencies: ["HapticCore"], path: "Tests", resources: [.copy("Fixtures")])
    ]
)
