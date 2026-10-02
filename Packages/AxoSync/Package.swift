// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AxoSync",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "AxoSync", targets: ["AxoSync"]),
    ],
    dependencies: [
        .package(path: "../AxoPersistence"),
    ],
    targets: [
        .target(
            name: "AxoSync",
            dependencies: [
                "AxoPersistence",
            ]
        ),
        .testTarget(
            name: "AxoSyncTests",
            dependencies: ["AxoSync"]
        ),
    ]
)
