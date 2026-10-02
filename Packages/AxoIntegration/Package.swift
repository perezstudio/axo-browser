// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AxoIntegration",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "AxoIntegration", targets: ["AxoIntegration"]),
    ],
    dependencies: [
        .package(path: "../AxoCore"),
    ],
    targets: [
        .target(
            name: "AxoIntegration",
            dependencies: [
                "AxoCore",
            ]
        ),
        .testTarget(
            name: "AxoIntegrationTests",
            dependencies: ["AxoIntegration"]
        ),
    ]
)
