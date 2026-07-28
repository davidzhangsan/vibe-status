// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "VibeStatus",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "VibeStatusCore", targets: ["VibeStatusCore"]),
        .executable(name: "vibe-status-probe", targets: ["VibeStatusProbe"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-nio.git",
            exact: "2.101.3"
        ),
    ],
    targets: [
        .target(
            name: "VibeStatusCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ],
            path: "Sources/VibeStatusCore"
        ),
        .testTarget(
            name: "VibeStatusCoreTests",
            dependencies: [
                "VibeStatusCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ],
            path: "Tests/VibeStatusCoreTests"
        ),
        .executableTarget(
            name: "VibeStatusProbe",
            dependencies: ["VibeStatusCore"],
            path: "Sources/VibeStatusProbe"
        ),
    ],
    swiftLanguageModes: [.v6]
)
