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
        // The command interpreter lives in a library rather than the executable so it can
        // be imported by tests — an executable target with top-level code in main.swift
        // cannot be.
        .target(
            name: "BuildSystemCLI",
            dependencies: [
                .product(name: "BuildSystemCore", package: "BuildSystemCore"),
            ],
            path: "build_system/CommandInterpreter"
        ),
        .executableTarget(
            name: "build_system",
            dependencies: [
                "BuildSystemCLI",
                .product(name: "BuildSystemCore", package: "BuildSystemCore"),
            ],
            path: "build_system",
            sources: ["main.swift"]
        ),
        .testTarget(
            name: "BuildSystemCLITests",
            dependencies: [
                "BuildSystemCLI",
                .product(name: "BuildSystemCore", package: "BuildSystemCore"),
            ],
            path: "build_system/Tests"
        ),
    ]
)
