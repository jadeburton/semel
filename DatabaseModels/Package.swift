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
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
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
