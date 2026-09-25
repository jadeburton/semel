// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "semel",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "semel", targets: ["semel"]),
        .executable(name: "semel-swift", targets: ["semel-swift"]),
        // The binary is `semelserv`; the target is `semel-server`, and the library it links
        // is `SemelServer`, not `SemelServ`. No target may be a case variant of any product
        // name: SwiftPM names build directories after targets, but Xcode names an
        // executable's after its product, so `SemelServ.build` and `semelserv.build` are one
        // directory on a case-insensitive volume and the two builds corrupt each other.
        .executable(name: "semelserv", targets: ["semel-server"]),
    ],
    dependencies: [
        .package(path: "SemelCore"),
        .package(path: "SemelNodeKit"),
        .package(path: "SemelProtocol"),
        .package(path: "SemelSwift"),
        .package(path: "SemelClang"),
        .package(path: "SemelApple"),
        .package(path: "SemelExamples"),
    ],
    targets: [
        // The command interpreter lives in a library rather than the executable so it can
        // be imported by tests — an executable target with top-level code in main.swift
        // cannot be. It sees the wire protocol and the node kit, never the engine: that
        // is what lets it become a separate process later without changing.
        .target(
            name: "SemelCLI",
            dependencies: [
                .product(name: "SemelNodeKit", package: "SemelNodeKit"),
                .product(name: "SemelProtocol", package: "SemelProtocol"),
                "SemelTransport",
            ],
            path: "semel/CommandInterpreter"
        ),
        // The server half: owns the engine behind one request handler. No sockets here;
        // the listener arrives with the semelserv executable.
        .target(
            name: "SemelServer",
            dependencies: [
                .product(name: "SemelCore", package: "SemelCore"),
                .product(name: "SemelNodeKit", package: "SemelNodeKit"),
                .product(name: "SemelProtocol", package: "SemelProtocol"),
                "SemelTransport",
            ],
            path: "semel/Server"
        ),
        // Frames over a socket. Both halves use it, so it is one target; it is not part of
        // SemelProtocol because the protocol package stays transport-free.
        .target(
            name: "SemelTransport",
            dependencies: [
                .product(name: "SemelProtocol", package: "SemelProtocol"),
            ],
            path: "semel/Transport"
        ),
        // What a test needs to run one of this package's executables as a subprocess:
        // where the binary is, a launch that captures output without blocking, a stop
        // with a timeout, and the wait for a socket file. A library rather than a test
        // target because two test targets cannot share a source file, and Foundation
        // only, so it never pulls XCTest into a product.
        .target(
            name: "SemelTestSupport",
            path: "semel/TestSupport"
        ),
        .testTarget(
            name: "SemelTransportTests",
            dependencies: [
                "SemelTransport",
                .product(name: "SemelProtocol", package: "SemelProtocol"),
            ],
            path: "semel/TransportTests"
        ),
        .executableTarget(
            name: "semel",
            dependencies: [
                "SemelCLI",
                "SemelTransport",
                .product(name: "SemelNodeKit", package: "SemelNodeKit"),
                .product(name: "SemelProtocol", package: "SemelProtocol"),
            ],
            path: "semel",
            // `sources:` already limits the target to one file; `exclude:` is what stops
            // SwiftPM reporting the sibling directories — every one of which is another
            // target's `path:` — as fifty-one unhandled files on every plan.
            exclude: [
                "CommandInterpreter",
                "Server",
                "ServerTests",
                "TestSupport",
                "Tests",
                "Transport",
                "TransportTests",
            ],
            sources: ["main.swift"]
        ),
        // The server: the engine behind a Unix-domain socket. The composition root for the
        // toolchains and the engine lives here now; `semel` is a client.
        .executableTarget(
            name: "semel-server",
            dependencies: [
                "SemelServer",
                "SemelTransport",
                .product(name: "SemelCore", package: "SemelCore"),
                .product(name: "SemelNodeKit", package: "SemelNodeKit"),
                .product(name: "SemelProtocol", package: "SemelProtocol"),
                .product(name: "SemelSwift", package: "SemelSwift"),
                .product(name: "SemelClang", package: "SemelClang"),
                .product(name: "SemelApple", package: "SemelApple"),
                .product(name: "SemelExamples", package: "SemelExamples"),
            ],
            path: "semel-server",
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
                .product(name: "SemelApple", package: "SemelApple"),
            ],
            path: "semel-swift/Library"
        ),
        .executableTarget(
            name: "semel-swift",
            dependencies: ["SemelSwiftTool"],
            path: "semel-swift",
            exclude: ["Library"],
            sources: ["main.swift"]
        ),
        .testTarget(
            name: "SemelServerTests",
            dependencies: [
                "SemelServer",
                "SemelCLI",
                "SemelTransport",
                "SemelTestSupport",
                "semel-server",
                .product(name: "SemelCore", package: "SemelCore"),
                .product(name: "SemelNodeKit", package: "SemelNodeKit"),
                .product(name: "SemelProtocol", package: "SemelProtocol"),
            ],
            path: "semel/ServerTests"
        ),
        // The only place a test can see the converter and the engine at once. SemelSwift
        // deliberately does not depend on SemelCore, so nothing inside it can check that
        // the formula it emits is *complete* — only that it parses. This target can. It
        // also runs the plugins over a real engine through InProcessConnection.
        .testTarget(
            name: "SemelCLITests",
            dependencies: [
                "SemelCLI",
                "SemelServer",
                "SemelSwiftTool",
                "SemelTransport",
                .product(name: "SemelCore", package: "SemelCore"),
                .product(name: "SemelNodeKit", package: "SemelNodeKit"),
                .product(name: "SemelProtocol", package: "SemelProtocol"),
                .product(name: "SemelSwift", package: "SemelSwift"),
                .product(name: "SemelClang", package: "SemelClang"),
                .product(name: "SemelApple", package: "SemelApple"),
            ],
            path: "semel/Tests"
        ),
        // Real projects through the three binaries together: the fixtures under
        // EndToEnd/Fixtures on every run, pinned external projects on opt-in
        // (SEMEL_E2E_EXTERNAL=1). Depending on the executable targets is what makes
        // `swift test` build them beside the test bundle, where the harness finds them.
        .testTarget(
            name: "SemelEndToEndTests",
            dependencies: [
                "SemelTestSupport",
                "semel",
                "semel-server",
                "semel-swift",
            ],
            path: "EndToEnd/Tests"
        ),
    ]
)
