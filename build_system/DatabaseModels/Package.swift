// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DatabaseModels",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "DatabaseModels", targets: ["DatabaseModels"]),
    ],
    dependencies: [
        // Use the local GRDB package available in the parent project
        .package(path: "../../GRDB.swift"),
    ],
    targets: [
        .target(
            name: "DatabaseModels",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/DatabaseModels"
        ),
    ]
)
