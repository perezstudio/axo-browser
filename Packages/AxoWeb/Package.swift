// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AxoWeb",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "AxoWeb", targets: ["AxoWeb"]),
    ],
    dependencies: [
        .package(path: "../AxoCore"),
    ],
    targets: [
        .target(
            name: "AxoWeb",
            dependencies: [
                "AxoCore",
            ]
        ),
        .testTarget(
            name: "AxoWebTests",
            dependencies: ["AxoWeb"]
        ),
    ]
)
