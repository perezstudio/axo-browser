// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AxoChromium",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "AxoChromium", targets: ["AxoChromium"]),
        // Fake engine classes for other targets' tests.
        .library(name: "AxoChromiumTestSupport", targets: ["AxoChromiumTestSupport"]),
    ],
    dependencies: [
        .package(path: "../AxoCore"),
        .package(path: "../AxoWeb"),
    ],
    targets: [
        // The Chromium engine's API (Objective-C protocols), copied from the axo-chromium fork.
        // Axo loads the engine framework at runtime and never links it.
        .target(name: "AxoEngineAPI"),
        .target(
            name: "AxoChromium",
            dependencies: [
                "AxoEngineAPI",
                "AxoCore",
                "AxoWeb",
            ]
        ),
        // Fake engine classes, written against the same protocols as the real framework.
        .target(name: "AxoChromiumTestSupport", dependencies: ["AxoEngineAPI"]),
        .testTarget(
            name: "AxoChromiumTests",
            dependencies: ["AxoChromium", "AxoChromiumTestSupport"]
        ),
    ]
)
