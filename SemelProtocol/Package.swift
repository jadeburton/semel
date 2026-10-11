// swift-tools-version: 5.9
import PackageDescription

// Everything that crosses the wire between Semel's processes, and nothing else: the
// prompt and the engine's server, and an engine and a cache server.
//
// It deliberately depends on no server. Anything the engine wants to send is mirrored here
// and mapped in `SemelServer`, never imported, so the wire format stays independent of the
// graph's schema. See docs/superpowers/specs/2026-09-12-semel-local-daemon-split-design.md.
let package = Package(
    name: "SemelProtocol",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "SemelProtocol", targets: ["SemelProtocol"]),
    ],
    dependencies: [
        // The error report carries a node's `ErrorDocument` as the value it published
        // (2026-10-09 error report design): the type is the node-authoring API's, and the
        // wire carries it rather than a mirror that would have to follow every case.
        .package(path: "../SemelNodeKit"),
        // A cache request names its entry by the `CacheKey` the cache defines (B-153), so a
        // key an engine computes and the key a cache server files are one type.
        .package(path: "../SemelCache"),
    ],
    targets: [
        .target(
            name: "SemelProtocol",
            dependencies: [
                .product(name: "SemelNodeKit", package: "SemelNodeKit"),
                .product(name: "SemelCache", package: "SemelCache"),
            ],
            path: "Sources/SemelProtocol"
        ),
        .testTarget(
            name: "SemelProtocolTests",
            dependencies: [
                "SemelProtocol",
                .product(name: "SemelCache", package: "SemelCache"),
            ],
            path: "Tests"
        ),
    ]
)
