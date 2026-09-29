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

    /// What the app prints: the framework's greeting, then what the plist and the JSON
    /// file of its synchronized folder say, each read from the bundle's resources at
    /// launch (B-77 item 2).
    static let printedLines = [greeting,
                               "Goodbye from a plist in the synchronized folder",
                               "A JSON file two folders down, copied flat"]

    /// The exported app loads the framework by its install name, finds it through the
    /// runpath the emitter gave it, and — the framework embedded under
    /// `Contents/Frameworks` — runs and prints the framework's greeting, and finds the
    /// plist and the JSON file its folder holds where Xcode puts them.
    static func checkApp(in out: URL) throws {
        let executable = out.appendingPathComponent("Greeter.app/Contents/MacOS/Greeter")
        try AppInspection.checkLoadsEmbeddedFramework(executable: executable, installName: installName)
        let printed = try run([executable.path], viaXcrun: false)
        let expected = printedLines.joined(separator: "\n")
        guard printed.trimmingCharacters(in: .whitespacesAndNewlines) == expected else {
            throw EndToEndFailure(step: "run the app", message: "printed '\(printed)', not '\(expected)'")
        }
        // Signed as a bundle, the framework with it (B-77), and the export verifies as the
        // whole it is: the framework's links travelled as links, from the push to here.
        try SignedBundleCheck.verified(out.appendingPathComponent("Greeter.app"))
        try SignedBundleCheck.signedAsPartOfTheBundle(executable)
        try SignedBundleCheck.signedAsPartOfTheBundle(out.appendingPathComponent("Greeter.app/Contents/Frameworks/Tiny.framework/Versions/A/Tiny"))
        try checkFrameworkLinks(in: out.appendingPathComponent("Greeter.app/Contents/Frameworks/Tiny.framework"))
    }

    /// The links a versioned framework has, as links in the export and not copies.
    private static func checkFrameworkLinks(in framework: URL) throws {
        let expected = ["Versions/Current": "A", "Tiny": "Versions/Current/Tiny", "Headers": "Versions/Current/Headers",
                        "Modules": "Versions/Current/Modules", "Resources": "Versions/Current/Resources"]
        for (name, target) in expected.sorted(by: { $0.key < $1.key }) {
            let found = try? FileManager.default.destinationOfSymbolicLink(atPath: framework.appendingPathComponent(name).path)
            guard found == target else {
                throw EndToEndFailure(step: "the framework's links",
                                      message: "\(framework.lastPathComponent)/\(name) is \(found.map { "a link to \($0)" } ?? "not a link"), not a link to \(target)")
            }
        }
    }

    @discardableResult
    private static func run(_ arguments: [String], viaXcrun: Bool = true) throws -> String {
        try AppInspection.run(arguments, viaXcrun: viaXcrun)
    }
}
