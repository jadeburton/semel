// swift-tools-version: 5.9
import PackageDescription

// The Apple platform tools as nodes: what an app bundle needs beyond compiled code.
//
// Not part of SemelSwift, because these are not Swift tools: `SemelSwift` compiles Swift
// wherever `swiftc` runs, and these compile resources for Apple bundles whatever language
// the code is in. Depends on SemelNodeKit and *not* on the engine, for the same reason the
// other toolchain packages do not.
let package = Package(
    name: "SemelApple",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "SemelApple", targets: ["SemelApple"]),
    ],
    dependencies: [
        .package(path: "../SemelNodeKit"),
        .package(path: "../SemelDatabaseModels"),
    ],
    targets: [
        .target(
            name: "SemelApple",
            dependencies: [
                .product(name: "SemelNodeKit", package: "SemelNodeKit"),
                .product(name: "SemelDatabaseModels", package: "SemelDatabaseModels"),
            ],
            path: "Sources/SemelApple"
        ),
        .testTarget(
            name: "SemelAppleTests",
            dependencies: ["SemelApple"],
            path: "Tests"
        ),
    ]
)
