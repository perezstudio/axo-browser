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
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
        // Tests only: they change the sidebar through TabStore, as the app does.
        .package(path: "../AxoCore"),
    ],
    targets: [
        .target(
            name: "AxoSync",
            dependencies: [
                "AxoPersistence",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "AxoSyncTests",
            dependencies: [
                "AxoSync",
                .product(name: "AxoCore", package: "AxoCore"),
            ]
        ),
    ]
)
