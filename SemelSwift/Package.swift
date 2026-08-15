// swift-tools-version: 5.9
import PackageDescription

// The Swift toolchain as node functions.
//
// Depends on SemelNodeKit and *not* on the engine. That absent dependency is the point of
// the split: this package cannot reach the graph even by accident, so the engine stays
// agnostic by construction rather than by discipline.
let package = Package(
    name: "SemelSwift",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "SemelSwift", targets: ["SemelSwift"]),
    ],
    dependencies: [
        .package(path: "../SemelNodeKit"),
        .package(path: "../DatabaseModels"),
    ],
    targets: [
        .target(
            name: "SemelSwift",
            dependencies: [
                .product(name: "SemelNodeKit", package: "SemelNodeKit"),
                .product(name: "DatabaseModels", package: "DatabaseModels"),
            ],
            path: "Sources/SemelSwift"
        ),
        .testTarget(
            name: "SemelSwiftTests",
            dependencies: ["SemelSwift"],
            path: "Tests"
        ),
    ]
)
