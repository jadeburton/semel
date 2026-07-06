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
        .package(path: "../../GRDB.swift"),
        .package(path: "../DatabaseModels"),
    ],
    targets: [
        .target(
            name: "BuildSystemCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "DatabaseModels", package: "DatabaseModels"),
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
