// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AxoImport",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "AxoImport", targets: ["AxoImport"]),
    ],
    dependencies: [
        .package(path: "../AxoCore"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
    ],
    targets: [
        .target(
            name: "AxoImport",
            dependencies: [
                "AxoCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "AxoImportTests",
            dependencies: ["AxoImport"]
        ),
    ]
)
