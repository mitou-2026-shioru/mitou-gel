// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ASRSmoke",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0")
    ],
    targets: [
        .executableTarget(name: "ASRSmoke", dependencies: [
            .product(name: "WhisperKit", package: "argmax-oss-swift"),
            .product(name: "HapticCore", package: "mitou-gel")
        ])
    ]
)
