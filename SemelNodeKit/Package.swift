// swift-tools-version: 5.9
import PackageDescription

// The node-authoring API: what a node function programs against, and nothing more.
//
// It deliberately does not depend on the engine. That absent dependency is what lets a
// toolchain package (SemelSwift, SemelClang) be written without being able to refer to the
// graph at all — agnosticism as a compiler guarantee rather than as discipline.
let package = Package(
    name: "SemelNodeKit",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "SemelNodeKit", targets: ["SemelNodeKit"]),
    ],
    dependencies: [
        .package(path: "../SemelDatabaseModels"),
    ],
    targets: [
        .target(
            name: "SemelNodeKit",
            dependencies: [
                .product(name: "SemelDatabaseModels", package: "SemelDatabaseModels"),
            ],
            path: "Sources/SemelNodeKit"
        ),
        .testTarget(
            name: "SemelNodeKitTests",
            dependencies: ["SemelNodeKit"],
            path: "Tests"
        ),
    ]
)
