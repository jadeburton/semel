// swift-tools-version: 5.9
import PackageDescription

// CMake projects as formulas: a parser for the CMake language, an evaluator for its
// declarative subset into a model of the project, and an emitter from that model to the
// formula and config a hand-written C project would carry (B-156).
//
// Depends on SemelNodeKit and *not* on the engine, like the toolchain packages. Nothing
// here touches a file system or a machine: files come in through a reader, the facts a
// condition is decided on come in as a value, and text goes out. That is what lets the
// same three stages run under `semel-cmake` today, writing the files once for a person to
// edit, and under a converter node later, should a project want the formula derived live.
let package = Package(
    name: "SemelCMake",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "SemelCMake", targets: ["SemelCMake"]),
    ],
    dependencies: [
        .package(path: "../SemelNodeKit"),
    ],
    targets: [
        .target(
            name: "SemelCMake",
            dependencies: [
                .product(name: "SemelNodeKit", package: "SemelNodeKit"),
            ],
            path: "Sources/SemelCMake"
        ),
        .testTarget(
            name: "SemelCMakeTests",
            dependencies: ["SemelCMake"],
            path: "Tests"
        ),
    ]
)
