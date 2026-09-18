// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MyApp",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "MyApp", targets: ["MainTarget"]),
    ],
    dependencies: [
        .package(path: "../MyLibrary"),
    ],
    targets: [
        .executableTarget(
            name: "MainTarget",
            dependencies: [
                "MyLibrary"
            ]
        )
    ]
)
