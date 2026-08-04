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
        .package(path: "../GRDB"),
    ],
    targets: [
        .target(
            name: "DatabaseModels",
            dependencies: [
                .product(name: "GRDB", package: "GRDB"),
            ],
            path: "Sources/DatabaseModels"
        ),
    ]
)
