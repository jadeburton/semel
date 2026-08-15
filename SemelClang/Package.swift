// swift-tools-version: 5.9
import PackageDescription

// The C/C++ toolchain as node functions.
//
// Depends on SemelNodeKit and *not* on the engine, for the same reason SemelSwift does:
// the absent dependency is what keeps the engine from acquiring knowledge of a toolchain
// by accident.
let package = Package(
    name: "SemelClang",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "SemelClang", targets: ["SemelClang"]),
    ],
    dependencies: [
        .package(path: "../SemelNodeKit"),
        .package(path: "../SemelDatabaseModels"),
    ],
    targets: [
        .target(
            name: "SemelClang",
            dependencies: [
                .product(name: "SemelNodeKit", package: "SemelNodeKit"),
                .product(name: "SemelDatabaseModels", package: "SemelDatabaseModels"),
            ],
            path: "Sources/SemelClang"
        ),
        .testTarget(
            name: "SemelClangTests",
            dependencies: ["SemelClang"],
            path: "Tests"
        ),
    ]
)
