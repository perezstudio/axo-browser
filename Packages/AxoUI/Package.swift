// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AxoUI",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "AxoUI", targets: ["AxoUI"]),
    ],
    dependencies: [
        .package(path: "../AxoCore"),
        .package(path: "../AxoWeb"),
        .package(url: "https://github.com/groue/GRDBQuery", from: "0.11.0"),
    ],
    targets: [
        .target(
            name: "AxoUI",
            dependencies: [
                "AxoCore",
                "AxoWeb",
                .product(name: "GRDBQuery", package: "GRDBQuery"),
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "AxoUIPackageTests",
            dependencies: ["AxoUI"]
        ),
    ]
)
