// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "build_system",
    platforms: [
        .macOS(.v13),
    ],
    dependencies: [
        .package(path: "SemelCore"),
        .package(path: "SemelSwift"),
        .package(path: "SemelClang"),
    ],
    targets: [
        // The command interpreter lives in a library rather than the executable so it can
        // be imported by tests — an executable target with top-level code in main.swift
        // cannot be.
        .target(
            name: "SemelCLI",
            dependencies: [
                .product(name: "SemelCore", package: "SemelCore"),
            ],
            path: "build_system/CommandInterpreter"
        ),
        .executableTarget(
            name: "semel",
            dependencies: [
                "SemelCLI",
                .product(name: "SemelCore", package: "SemelCore"),
                .product(name: "SemelSwift", package: "SemelSwift"),
                .product(name: "SemelClang", package: "SemelClang"),
            ],
            path: "build_system",
            sources: ["main.swift"]
        ),
        // The only place a test can see the converter and the engine at once. SemelSwift
        // deliberately does not depend on SemelCore, so nothing inside it can check that
        // the formula it emits is *complete* — only that it parses. This target can.
        .testTarget(
            name: "SemelCLITests",
            dependencies: [
                "SemelCLI",
                .product(name: "SemelCore", package: "SemelCore"),
                .product(name: "SemelSwift", package: "SemelSwift"),
            ],
            path: "build_system/Tests"
        ),
    ]
)
