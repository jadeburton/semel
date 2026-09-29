//
//  BinaryTargetFixture.swift
//  SemelEndToEndTests
//
//  The `BinaryTargetApp` fixture's binary framework (B-77). A vendor ships an
//  `.xcframework` it built; the repository holds no binary, so the test builds one the way
//  a vendor would — `clang -dynamiclib` into a versioned `Tiny.framework`, then
//  `xcodebuild -create-xcframework` — into the copy the run builds, and afterwards asks the
//  exported app what it loads and runs it.
//

import Foundation

enum BinaryTargetFixture {

    /// The install name the framework is built with, which the app's executable records:
    /// the versioned layout's, as a Mac framework — Sparkle's too — has it.
    static let installName = "@rpath/Tiny.framework/Versions/A/Tiny"

    /// What the framework's function returns, and so what the app prints.
    static let greeting = "Hello from Tiny.framework"

    /// Builds `Greeting/Tiny.xcframework` in `buildFolder` from the sources in `Tiny/`: a
    /// Mac framework with its binary, headers, module map and Info.plist under
    /// `Versions/A` and the links a framework has above it.
    static func buildXCFramework(in buildFolder: URL) throws {
        let fileManager = FileManager.default
        let sources = buildFolder.appendingPathComponent("Tiny", isDirectory: true)
        let staging = buildFolder.appendingPathComponent(".tiny-build", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        let framework = staging.appendingPathComponent("Tiny.framework", isDirectory: true)
        let version = framework.appendingPathComponent("Versions/A", isDirectory: true)
        for folder in ["Headers", "Modules", "Resources"] {
            try fileManager.createDirectory(at: version.appendingPathComponent(folder, isDirectory: true),
                                            withIntermediateDirectories: true)
        }
        try run(["clang", "-dynamiclib", "-arch", "arm64", "-mmacosx-version-min=14.0",
                 "-install_name", installName,
                 "-o", version.appendingPathComponent("Tiny").path,
                 sources.appendingPathComponent("Tiny.c").path])
        try fileManager.copyItem(at: sources.appendingPathComponent("Tiny.h"),
                                 to: version.appendingPathComponent("Headers/Tiny.h"))
        try fileManager.copyItem(at: sources.appendingPathComponent("module.modulemap"),
                                 to: version.appendingPathComponent("Modules/module.modulemap"))
        try fileManager.copyItem(at: sources.appendingPathComponent("Info.plist"),
                                 to: version.appendingPathComponent("Resources/Info.plist"))
        try fileManager.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path,
                                           withDestinationPath: "A")
        for name in ["Tiny", "Headers", "Modules", "Resources"] {
            try fileManager.createSymbolicLink(atPath: framework.appendingPathComponent(name).path,
                                               withDestinationPath: "Versions/Current/\(name)")
        }
        try run(["xcodebuild", "-create-xcframework", "-framework", framework.path,
                 "-output", buildFolder.appendingPathComponent("Greeting/Tiny.xcframework").path])
    }

    /// The exported app loads the framework by its install name, finds it through the
    /// runpath the emitter gave it, and — the framework embedded under
    /// `Contents/Frameworks` — runs and prints the framework's greeting.
    static func checkApp(in out: URL) throws {
        let executable = out.appendingPathComponent("Greeter.app/Contents/MacOS/Greeter")
        try AppInspection.checkLoadsEmbeddedFramework(executable: executable, installName: installName)
        let printed = try run([executable.path], viaXcrun: false)
        guard printed.trimmingCharacters(in: .whitespacesAndNewlines) == greeting else {
            throw EndToEndFailure(step: "run the app", message: "printed '\(printed)', not '\(greeting)'")
        }
        // Signed as a bundle, the framework with it (B-77). The export does not verify as
        // a whole: the framework's links arrive as copies, which a versioned framework's
        // signature does not allow, though the signer lays them as links while it signs.
        try SignedBundleCheck.signedAsPartOfTheBundle(executable)
        try SignedBundleCheck.signedAsPartOfTheBundle(out.appendingPathComponent("Greeter.app/Contents/Frameworks/Tiny.framework/Versions/A/Tiny"))
    }

    @discardableResult
    private static func run(_ arguments: [String], viaXcrun: Bool = true) throws -> String {
        try AppInspection.run(arguments, viaXcrun: viaXcrun)
    }
}
