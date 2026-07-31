// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "build_system",
    platforms: [
        .macOS(.v13),
    ],
    dependencies: [
        .package(path: "BuildSystemCore"),
    ],
    targets: [
        .executableTarget(
            name: "build_system",
            dependencies: [
                .product(name: "BuildSystemCore", package: "BuildSystemCore"),
            ],
            path: "build_system"
        ),
    ]
)
