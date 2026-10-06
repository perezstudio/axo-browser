// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AxoPersistence",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "AxoPersistence", targets: ["AxoPersistence"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
    ],
    targets: [
        .target(
            name: "AxoPersistence",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "AxoPersistenceTests",
            dependencies: ["AxoPersistence"]
        ),
    ]
)
