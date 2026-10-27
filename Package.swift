// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "LFData",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
    ],
    products: [
        .library(
            name: "LFData",
            targets: ["LFData"]
        ),
    ],
    targets: [
        .target(
            name: "LFData",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "LFDataTests",
            dependencies: ["LFData"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ]
)
