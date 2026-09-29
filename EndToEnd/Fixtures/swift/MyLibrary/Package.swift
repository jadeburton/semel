// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MyLibrary",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "MyLibrary", targets: ["MyLibraryTargetA", "MyLibraryTargetB"]),
    ],
    dependencies: [
//        .package(path: "../../GRDB.swift"),
//        .package(path: "../DatabaseModels"),
    ],
    targets: [
        .target(
            name: "MyLibraryTargetA",
            dependencies: [
//                .product(name: "GRDB", package: "GRDB.swift"),
//                .product(name: "DatabaseModels", package: "DatabaseModels"),
            ]
        ),
        .target(
            name: "MyLibraryTargetB",
            dependencies: [
            ],
            swiftSettings: [
                .enableUpcomingFeature("BareSlashRegexLiterals"),
                .define("MY_LIBRARY_SETTINGS"),
            ]
        )/*,
        .testTarget(
            name: "MyLibraryTests",
            dependencies: ["MyLibrary"]
        ),*/
    ]
)
