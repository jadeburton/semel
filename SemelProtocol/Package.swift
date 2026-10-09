// swift-tools-version: 5.9
import PackageDescription

// Everything that crosses the wire between `semel` and `semelserv`, and nothing else.
//
// It deliberately depends on Foundation alone. Anything the engine wants to send is
// mirrored here and mapped in `SemelServer`, never imported, so the wire format stays
// independent of the persisted schema and a client that speaks one role does not link the
// database. See docs/superpowers/specs/2026-09-12-semel-local-daemon-split-design.md.
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
    ],
    targets: [
        .target(
            name: "SemelProtocol",
            dependencies: [
                .product(name: "SemelNodeKit", package: "SemelNodeKit"),
            ],
            path: "Sources/SemelProtocol"
        ),
        .testTarget(
            name: "SemelProtocolTests",
            dependencies: ["SemelProtocol"],
            path: "Tests"
        ),
    ]
)
