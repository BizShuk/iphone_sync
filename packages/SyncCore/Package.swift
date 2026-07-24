// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SyncCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(name: "SyncCore", targets: ["SyncCore"]),
        .library(name: "MacReceiverKit", targets: ["MacReceiverKit"]),
    ],
    targets: [
        .target(
            name: "SyncCore",
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "SyncCoreTests",
            dependencies: ["SyncCore"]
        ),
        .target(
            name: "MacReceiverKit",
            dependencies: ["SyncCore"]
        ),
        .testTarget(
            name: "MacReceiverKitTests",
            dependencies: ["MacReceiverKit", "SyncCore"]
        ),
    ]
)
