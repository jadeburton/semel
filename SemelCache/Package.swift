// swift-tools-version: 5.9
import PackageDescription

// What a build cache is, independent of the engine that fills it: the entry, the material a
// key is taken of and its hashing, the entry's cost, the size accounting and the order a trim
// evicts in, and the `CacheStore` protocol a store implements.
//
// It deliberately depends on the node kit alone. The engine links it for its local cache and
// a cache server will link it for the shared one, so one definition of an entry serves both
// and a key an engine computes is the key the server stores. A server that had to link the
// engine to read an entry would carry the graph, the toolchains and the database it has no
// use for; that absent dependency on `SemelCore` is what this package is for.
let package = Package(
    name: "SemelCache",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "SemelCache", targets: ["SemelCache"]),
    ],
    dependencies: [
        .package(path: "../SemelNodeKit"),
    ],
    targets: [
        .target(
            name: "SemelCache",
            dependencies: [
                .product(name: "SemelNodeKit", package: "SemelNodeKit"),
            ],
            path: "Sources/SemelCache"
        ),
        .testTarget(
            name: "SemelCacheTests",
            dependencies: ["SemelCache"],
            path: "Tests"
        ),
    ]
)
