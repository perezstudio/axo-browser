// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AxoCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "AxoCore", targets: ["AxoCore"]),
    ],
    dependencies: [
        .package(path: "../AxoPersistence"),
    ],
    targets: [
        .target(
            name: "AxoCore",
            dependencies: [
                "AxoPersistence",
            ]
        ),
        .testTarget(
            name: "AxoCoreTests",
            dependencies: ["AxoCore"]
        ),
    ]
)
