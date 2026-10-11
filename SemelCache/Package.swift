// swift-tools-version: 5.9
import PackageDescription

// What a build cache is, independent of the engine that fills it: the entry, the material a
// key is taken of and its hashing, the typed key, the entry's cost, the size accounting and
// the order a trim evicts in, the `CacheStore` protocol a store implements, and the one
// SQLite implementation of it over the cache's tables.
//
// It deliberately depends on no engine. The engine links it for its local cache and a cache
// server links it for the shared one, so one definition of an entry serves both, a key an
// engine computes is the key the server stores, and the queries over the cache's tables are
// written once for the two databases that hold them — the graph's, and a cache server's
// index. A server that had to link the engine to read an entry would carry the graph, the
// toolchains and the database it has no use for; that absent dependency on `SemelCore` is
// what this package is for. The database models are linked for the cache's tables and the
// prepared-statement helpers; the node kit links them already.
let package = Package(
    name: "SemelCache",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "SemelCache", targets: ["SemelCache"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(path: "../SemelDatabaseModels"),
        .package(path: "../SemelNodeKit"),
    ],
    targets: [
        .target(
            name: "SemelCache",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SemelDatabaseModels", package: "SemelDatabaseModels"),
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
