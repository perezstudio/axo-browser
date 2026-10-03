// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AxoExtensions",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "AxoExtensions", targets: ["AxoExtensions"]),
        // Standalone and open-sourceable: no Axo dependencies.
        .library(name: "AxoCRX", targets: ["AxoCRX"]),
    ],
    dependencies: [
        .package(path: "../AxoCore"),
        .package(path: "../AxoWeb"),
    ],
    targets: [
        .target(name: "AxoCRX"),
        // Test fixtures (zip and signed CRX builders, a loopback web server). Not a product.
        .target(name: "AxoExtensionsTestSupport", dependencies: ["AxoCRX"]),
        .target(
            name: "AxoExtensions",
            dependencies: [
                "AxoCRX",
                "AxoCore",
                "AxoWeb",
            ]
        ),
        .testTarget(
            name: "AxoCRXTests",
            dependencies: ["AxoCRX", "AxoExtensionsTestSupport"]
        ),
        .testTarget(
            name: "AxoExtensionsTests",
            dependencies: ["AxoExtensions", "AxoExtensionsTestSupport"]
        ),
    ]
)
