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
        // Fixture builders (zip and signed CRX files) for the tests below. Not a product.
        .target(name: "AxoCRXTestSupport", dependencies: ["AxoCRX"]),
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
            dependencies: ["AxoCRX", "AxoCRXTestSupport"]
        ),
        .testTarget(
            name: "AxoExtensionsTests",
            dependencies: ["AxoExtensions", "AxoCRXTestSupport"]
        ),
    ]
)
