// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AxoInspector",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "AxoInspector", targets: ["AxoInspector"]),
    ],
    dependencies: [
        .package(path: "../AxoWeb"),
    ],
    targets: [
        .target(
            name: "AxoInspector",
            dependencies: [
                "AxoWeb",
            ]
        ),
        .testTarget(
            name: "AxoInspectorTests",
            dependencies: ["AxoInspector"]
        ),
    ]
)
