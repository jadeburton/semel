// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "semel",
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
            path: "semel/CommandInterpreter"
        ),
        .executableTarget(
            name: "semel",
            dependencies: [
                "SemelCLI",
                .product(name: "SemelCore", package: "SemelCore"),
                .product(name: "SemelSwift", package: "SemelSwift"),
                .product(name: "SemelClang", package: "SemelClang"),
            ],
            path: "semel",
            sources: ["main.swift"]
        ),
        // The Swift conversion tool, outside the engine. `prepare` copies the roots'
        // resolved dependencies into `<folder>/Dependencies/<name>` so every file a build
        // needs is inside the input file system, found by one rule, and derives the formula
        // and config for the tree. It depends on the toolchain packages, not on
        // the engine: the config it writes is what their nodes will read, so it asks them
        // which namespaces and SDK facts those are. The work lives in a library so it can
        // be tested.
        .target(
            name: "SemelSwiftTool",
            dependencies: [
                .product(name: "SemelSwift", package: "SemelSwift"),
                .product(name: "SemelClang", package: "SemelClang"),
            ],
            path: "semel-swift/Library"
        ),
        .executableTarget(
            name: "semel-swift",
            dependencies: ["SemelSwiftTool"],
            path: "semel-swift",
            sources: ["main.swift"]
        ),
        // The only place a test can see the converter and the engine at once. SemelSwift
        // deliberately does not depend on SemelCore, so nothing inside it can check that
        // the formula it emits is *complete* — only that it parses. This target can.
        .testTarget(
            name: "SemelCLITests",
            dependencies: [
                "SemelCLI",
                "SemelSwiftTool",
                .product(name: "SemelCore", package: "SemelCore"),
                .product(name: "SemelSwift", package: "SemelSwift"),
                .product(name: "SemelClang", package: "SemelClang"),
            ],
            path: "semel/Tests"
        ),
    ]
)
