// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AxoExtensions",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "AxoExtensions", targets: ["AxoExtensions"]),
    ],
    dependencies: [
        .package(path: "../AxoCore"),
        .package(path: "../AxoWeb"),
    ],
    targets: [
        .target(
            name: "AxoExtensions",
            dependencies: [
                "AxoCore",
                "AxoWeb",
            ]
        ),
        .testTarget(
            name: "AxoExtensionsTests",
            dependencies: ["AxoExtensions"]
        ),
    ]
)
