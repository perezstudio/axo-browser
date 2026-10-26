// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AxoWeb",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "AxoWeb", targets: ["AxoWeb"]),
        // A fake engine for other packages' tests.
        .library(name: "AxoWebTestSupport", targets: ["AxoWebTestSupport"]),
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
        // A fake engine (no browser behind it) for testing the pool and its callers.
        .target(name: "AxoWebTestSupport", dependencies: ["AxoCore", "AxoWeb"]),
        .testTarget(
            name: "AxoWebTests",
            dependencies: ["AxoWeb", "AxoWebTestSupport"]
        ),
    ]
)
