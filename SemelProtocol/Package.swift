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
    targets: [
        .target(
            name: "SemelProtocol",
            path: "Sources/SemelProtocol"
        ),
        .testTarget(
            name: "SemelProtocolTests",
            dependencies: ["SemelProtocol"],
            path: "Tests"
        ),
    ]
)
