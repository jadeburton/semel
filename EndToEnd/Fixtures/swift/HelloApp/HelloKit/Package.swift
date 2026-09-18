// swift-tools-version: 6.0
import PackageDescription

// A library the app imports and links through the package's product trees — what an
// Xcode project does with every package it references.
let package = Package(
    name: "HelloKit",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "HelloKit", targets: ["HelloKit"]),
    ],
    targets: [
        .target(name: "HelloKit", dependencies: ["HelloCore"]),
        .target(name: "HelloCore"),
    ]
)
