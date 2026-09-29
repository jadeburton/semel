// swift-tools-version: 5.9
import PackageDescription

// A library over a binary target (B-77): `Tiny.xcframework` is not in the repository — the
// end-to-end test builds it from `../Tiny` with `clang -dynamiclib` and
// `xcodebuild -create-xcframework` before the build, as a vendor would ship it.
let package = Package(
    name: "Greeting",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Greeting", targets: ["Greeting"]),
    ],
    targets: [
        .target(name: "Greeting", dependencies: ["Tiny"]),
        .binaryTarget(name: "Tiny", path: "Tiny.xcframework"),
    ]
)
