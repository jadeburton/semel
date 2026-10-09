// swift-tools-version: 5.9
import CompilerPluginSupport
import PackageDescription

// A package macro and the toolchain's, in one executable (B-80). `StringifyMacros` is the
// macro, built as the executable the compiler runs; `Stringify` declares it, and `MacroApp`
// expands it through `Stringify`, so the executable reaches a compile two targets away. The
// app also uses `@Observable` and SwiftData's `@Model`, whose macros the toolchain and the
// macOS platform ship.
let package = Package(
    name: "MacroApp",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "MacroApp", targets: ["MacroApp"]),
    ],
    targets: [
        .macro(name: "StringifyMacros"),
        .target(name: "Stringify", dependencies: ["StringifyMacros"]),
        .executableTarget(name: "MacroApp", dependencies: ["Stringify"]),
    ]
)
