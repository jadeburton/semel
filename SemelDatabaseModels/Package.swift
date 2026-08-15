// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SemelDatabaseModels",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "SemelDatabaseModels", targets: ["SemelDatabaseModels"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        .target(
            name: "SemelDatabaseModels",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/SemelDatabaseModels"
        ),
    ]
)
