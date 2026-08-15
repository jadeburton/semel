// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BuildSystemCore",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "BuildSystemCore", targets: ["BuildSystemCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(path: "../DatabaseModels"),
        .package(path: "../SemelNodeKit"),
    ],
    targets: [
        .target(
            name: "BuildSystemCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "DatabaseModels", package: "DatabaseModels"),
                .product(name: "SemelNodeKit", package: "SemelNodeKit"),
            ],
            path: "Sources/BuildSystemCore"
        ),
        .testTarget(
            name: "BuildSystemCoreTests",
            dependencies: ["BuildSystemCore"],
            path: "Tests"
        ),
    ]
)
