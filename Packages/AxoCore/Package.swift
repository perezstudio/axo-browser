// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AxoCore",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "AxoCore", targets: ["AxoCore"]),
    ],
    dependencies: [
        .package(path: "../AxoPersistence"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
    ],
    targets: [
        .target(
            name: "AxoCore",
            dependencies: [
                "AxoPersistence",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "AxoCoreTests",
            dependencies: ["AxoCore"]
        ),
    ]
)
