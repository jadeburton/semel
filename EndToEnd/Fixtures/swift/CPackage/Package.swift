// swift-tools-version: 5.9
import PackageDescription

// A C target the way larger packages write one (B-55): sources in nested folders, a
// folder and a file left out by `exclude:`, public headers somewhere other than
// `include`, a define the sources refuse to build without, and a header found only by
// `.headerSearchPath`. A Swift executable imports
// it, and a C executable links it with nothing Swift in it at all. What the link needs
// beyond the objects comes from the manifest and the sources: a framework and a library,
// one of them on this platform only, the C++ runtime for a `.cpp`, and assembly both
// preprocessed and not.
let package = Package(
    name: "CPackage",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "App", targets: ["App"]),
        .executable(name: "ctool", targets: ["CTool"]),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: ["CLib"]
        ),
        .executableTarget(
            name: "CTool",
            dependencies: ["CLib"]
        ),
        .target(
            name: "CLib",
            exclude: ["broken", "skip.c", "NOTES.txt"],
            publicHeadersPath: "api",
            cSettings: [
                .define("CLIB_ANSWER", to: "42"),
                .define("CLIB_ON_WINDOWS", .when(platforms: [.windows])),
                .headerSearchPath("core/detail"),
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedLibrary("z", .when(platforms: [.macOS])),
                // Linked, the link would fail: no such library.
                .linkedLibrary("clib_linux_only", .when(platforms: [.linux])),
            ]
        ),
    ]
)
