// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SyncCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "SyncCore", targets: ["SyncCore"]),
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
    ]
)
