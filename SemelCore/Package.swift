// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SemelCore",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "SemelCore", targets: ["SemelCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(path: "../SemelDatabaseModels"),
        .package(path: "../SemelNodeKit"),
    ],
    targets: [
        .target(
            name: "SemelCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SemelDatabaseModels", package: "SemelDatabaseModels"),
                .product(name: "SemelNodeKit", package: "SemelNodeKit"),
            ],
            path: "Sources/SemelCore"
        ),
        .testTarget(
            name: "SemelCoreTests",
            dependencies: ["SemelCore"],
            path: "Tests"
        ),
    ]
)
