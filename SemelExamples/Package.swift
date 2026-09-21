// swift-tools-version: 5.9
import PackageDescription

// Nodes that exist to be read: the reference copies of what docs/tutorial builds by hand.
//
// Depends on SemelNodeKit and *not* on the engine, like the toolchain packages: a node
// author sees the node-authoring API and nothing else. Nothing a real build depends on
// belongs here.
let package = Package(
    name: "SemelExamples",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "SemelExamples", targets: ["SemelExamples"]),
    ],
    dependencies: [
        .package(path: "../SemelNodeKit"),
        .package(path: "../SemelDatabaseModels"),
    ],
    targets: [
        .target(
            name: "SemelExamples",
            dependencies: [
                .product(name: "SemelNodeKit", package: "SemelNodeKit"),
                .product(name: "SemelDatabaseModels", package: "SemelDatabaseModels"),
            ],
            path: "Sources/SemelExamples"
        ),
        .testTarget(
            name: "SemelExamplesTests",
            dependencies: ["SemelExamples"],
            path: "Tests"
        ),
    ]
)
