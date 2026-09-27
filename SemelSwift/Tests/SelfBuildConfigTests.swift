//
//  SelfBuildConfigTests.swift
//  SemelSwiftTests
//
//  Guards this repository's own semel.config against what its Swift tools actually
//  require. Nothing defaults any more, so the moment one of the RequiredSettings types
//  grows a new key, every self-build fails until someone edits the file by hand -- this is
//  what makes that discovery happen here, in CI, instead of on whoever next tries to build
//  this tree with Semel.
//
//  One config file for the tree, beside the root Package.swift that semel.fmla names. Every
//  node of the build -- the dependency packages' readers and compilers included -- selects
//  from the config file the root package owns (B-10), so the copies that once sat beside
//  each nested package are gone and nothing reads a config from anywhere else.
//

@testable import SemelSwift
import Foundation
import SemelNodeKit
import XCTest

final class SelfBuildConfigTests: SemelSwiftTestCase {

    /// The repository root, found relative to this file rather than the working
    /// directory: `swift test` runs from the package folder, not the repo root that
    /// the config files actually live in.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // SemelSwift
            .deletingLastPathComponent()   // semel
    }

    /// The folders whose config file a build of this tree reads: only the root package's,
    /// the one `semel.fmla` names. The nested packages are its dependencies and select from
    /// the same file.
    private static func packageFolders() throws -> [URL] {
        [repositoryRoot]
    }

    private static func configText(inPackageFolder folder: URL) throws -> String {
        let path = folder.appendingPathComponent(SwiftFormulaConverter.configFileName).path
        guard FileManager.default.fileExists(atPath: path) else {
            XCTFail("""
                No \(SwiftFormulaConverter.configFileName) beside \(folder.path)/Package.swift.

                Discovery builds every pinned Package.swift it finds, and each selects from the \
                config file beside it. Configuration does not inherit, so this package's nodes \
                would fail with a missing-setting error. Copy the repository root's file here.
                """)
            return ""
        }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    /// Selects one namespace out of the whole file, stripping the prefix exactly the way
    /// `ConfigFilter` does: a whole dot-delimited segment, not a raw string prefix, so
    /// `swift.compiler` cannot also claim `swift.compilerPlugin`.
    private func subset(_ all: [String: String], under prefix: String) -> [String: String] {
        let qualifier = prefix + "."
        var selected: [String: String] = [:]
        for (key, value) in all where key.hasPrefix(qualifier) {
            let bare = String(key.dropFirst(qualifier.count))
            guard !bare.isEmpty else { continue }
            selected[bare] = value
        }
        return selected
    }

    // MARK: - The root has one, and it is the only one

    func test_theRootPackageHasAConfigFileBesideItsManifest() throws {
        _ = try Self.configText(inPackageFolder: Self.repositoryRoot)  // fails, naming the folder, if absent
    }

    /// A config beside a nested package is dead: nothing selects from it, and a copy that
    /// nobody reads is the one that drifts. The formula at the root names the package it
    /// builds, so a nested `Package.swift` on its own creates no builder either.
    func test_noNestedPackageCarriesAConfigFileOfItsOwn() throws {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: Self.repositoryRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))

        // The end-to-end fixtures are projects of their own, each with the project file
        // its formula names (B-109); none is a package of this tree.
        for case let url as URL in enumerator
        where url.lastPathComponent == SwiftFormulaConverter.configFileName
            && url.deletingLastPathComponent().path != Self.repositoryRoot.path
            && !url.path.contains("/EndToEnd/Fixtures/") {
            XCTFail("\(url.path) is a config file nothing reads; the root's is the only one")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.repositoryRoot.appendingPathComponent("semel.fmla").path),
                      "the root formula that names this tree's package is missing")
    }

    // MARK: - What the types require

    /// What the machine file supplies under every namespace: the tool's descriptor, with
    /// the SDK facts a namespace declares (B-109). Stood in for here with one machine's
    /// values, because the file itself is written by `prepare` and never committed; the
    /// keys are what the test is about, not the values.
    private static let machineHalf = [
        "toolDescriptor.name":         "swiftc",
        "toolDescriptor.version":      "Apple Swift version 6.3.3",
        "toolDescriptor.platform":     "macOS",
        "toolDescriptor.architecture": "arm64",
    ]

    /// The keys a project file must not carry: they describe the machine, and a project
    /// file that pins them builds on one machine only, which is what the split exists to
    /// end. `sdkVersion` is the one that caught the repository's own file (B-109
    /// residual 1): pinned to one SDK build, it failed the self-build everywhere else.
    private static let machineOnlyKeyPrefixes = ["toolDescriptor.", "sdk"]

    /// Runs `check` against the named namespace of every config file in the tree, laid
    /// over the machine's half, so a file that is present but short of a project key
    /// fails here rather than mid-build.
    private func forEachConfigFile(namespace: String,
                                   literals: [String: String] = [:],
                                   check: (String, [String: String]) throws -> Void) throws {
        for folder in try Self.packageFolders() {
            let all = [String: String](plainText: try Self.configText(inPackageFolder: folder))
            try check(folder.path, Self.machineHalf.mergedWith(subset(all, under: namespace)).mergedWith(literals))
        }
    }

    /// `moduleName` is not in the file -- it reaches the real node as a manifest-derived
    /// literal, merged in beside the selector's output (see SwiftFormulaConverter). That
    /// merge is stood in for here, so this test checks exactly what the file owes: every
    /// other required key in `swift.compiler` that the machine file does not supply.
    func test_swiftCompilerNamespaceSatisfiesSwiftCompilerConfiguration() throws {
        try forEachConfigFile(namespace: SwiftCompilerConfiguration.settingNamespace,
                              literals: ["moduleName": "Test"]) { path, settings in
            XCTAssertNoThrow(try SwiftCompilerConfiguration(properties: settings), path)
        }
    }

    /// Same reasoning as the compiler above, but for `outputName` and `linkage`, the
    /// linker's own manifest-derived literals.
    func test_swiftLinkerNamespaceSatisfiesSwiftLinkerConfiguration() throws {
        try forEachConfigFile(namespace: SwiftLinkerConfiguration.settingNamespace,
                              literals: ["outputName": "Test", "linkage": "executable"]) { path, settings in
            XCTAssertNoThrow(try SwiftLinkerConfiguration(properties: settings), path)
        }
    }

    /// No literals here: every setting `SwiftPackageReaderConfiguration` requires is a
    /// toolDescriptor field, and all of those come from the machine file.
    func test_swiftPackageReaderNamespaceSatisfiesSwiftPackageReaderConfiguration() throws {
        try forEachConfigFile(namespace: SwiftPackageReaderConfiguration.settingNamespace) { path, settings in
            XCTAssertNoThrow(try SwiftPackageReaderConfiguration(properties: settings), path)
        }
    }

    /// The project file carries the project's choices and nothing about this machine, so
    /// that the self-build runs wherever `prepare` has written the machine file — the
    /// end-to-end roster's copy, another developer's checkout, CI.
    func test_theProjectFileCarriesNoMachineFacts() throws {
        let all = [String: String](plainText: try Self.configText(inPackageFolder: Self.repositoryRoot))
        for namespace in [SwiftCompilerConfiguration.settingNamespace,
                          SwiftLinkerConfiguration.settingNamespace,
                          SwiftPackageReaderConfiguration.settingNamespace] {
            for key in subset(all, under: namespace).keys.sorted()
            where Self.machineOnlyKeyPrefixes.contains(where: { key.hasPrefix($0) }) {
                XCTFail("\(namespace).\(key) is the machine's, written by prepare into semel.machine.config, not the project's")
            }
        }
    }
}
