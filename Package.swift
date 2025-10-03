// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "SwiftDataCounter",
    platforms: [
        .iOS(.v17),
        .macCatalyst(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .visionOS(.v1),
        .watchOS(.v10)
    ],
    products: [
        .library(
            name: "SwiftDataCounter",
            targets: ["SwiftDataCounter"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/markbattistella/SimpleLogger", from: "2.0.0")
    ],
    targets: [
        .target(
            name: "SwiftDataCounter",
            dependencies: ["SimpleLogger"],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        )
    ]
)
