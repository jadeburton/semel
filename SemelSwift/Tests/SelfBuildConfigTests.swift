//
//  SelfBuildConfigTests.swift
//  SemelSwiftTests
//
//  Guards this repository's own semel.config files against what its Swift tools actually
//  require. Nothing defaults any more, so the moment one of the RequiredSettings types
//  grows a new key, every self-build fails until someone edits the files by hand -- this is
//  what makes that discovery happen here, in CI, instead of on whoever next tries to build
//  this tree with Semel.
//
//  There is one config file per package rather than one for the tree. Discovery creates a
//  ProjectBuilder for every pinned Package.swift it finds, each selecting from the file
//  beside it, and configuration does not inherit -- so every package needs its own copy.
//  Copies drift, which is why the first test here compares them byte for byte.
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

    /// Every folder in this tree holding a `Package.swift`, which is exactly the set
    /// discovery turns into a ProjectBuilder and so exactly the set that needs a config
    /// file. Derived rather than listed, so adding a package to the tree makes these tests
    /// fail rather than quietly leaving the new package unconfigured.
    private static func packageFolders() throws -> [URL] {
        let root = repositoryRoot
        var found: [URL] = []
        // `.skipsHiddenFiles` is what keeps `.build` out, and it has to: a build directory
        // holds a checked-out copy of every dependency's manifest, none of which are
        // packages this repository configures.
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]))

        for case let url as URL in enumerator {
            guard url.lastPathComponent == "Package.swift" else { continue }
            found.append(url.deletingLastPathComponent())
        }
        return found.sorted { $0.path < $1.path }
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

    // MARK: - Every package has one, and they all say the same thing

    func test_everyPackageInThisTreeHasAConfigFileBesideItsManifest() throws {
        let folders = try Self.packageFolders()

        XCTAssertFalse(folders.isEmpty, "no Package.swift found under \(Self.repositoryRoot.path)")
        for folder in folders {
            _ = try Self.configText(inPackageFolder: folder)  // fails, naming the folder, if absent
        }
    }

    /// Six copies of one file drift the moment somebody edits the one they happened to open.
    /// Compared as text rather than as parsed settings, so a divergent comment -- which is
    /// how the explanation of *why* there are six goes stale -- fails too.
    func test_everyConfigFileInThisTreeIsIdenticalToTheRootsOne() throws {
        let rootText = try Self.configText(inPackageFolder: Self.repositoryRoot)

        for folder in try Self.packageFolders() where folder.path != Self.repositoryRoot.path {
            XCTAssertEqual(try Self.configText(inPackageFolder: folder), rootText,
                           "\(folder.path)/semel.config has drifted from the repository root's")
        }
    }

    // MARK: - What the types require

    /// Runs `check` against the named namespace of every config file in the tree, so a file
    /// that is present but short of a key fails here rather than mid-build.
    private func forEachConfigFile(namespace: String,
                                   literals: [String: String] = [:],
                                   check: (String, [String: String]) throws -> Void) throws {
        for folder in try Self.packageFolders() {
            let all = [String: String](plainText: try Self.configText(inPackageFolder: folder))
            try check(folder.path, subset(all, under: namespace).mergedWith(literals))
        }
    }

    /// `moduleName` is not in the file -- it reaches the real node as a manifest-derived
    /// literal, merged in beside the selector's output (see SwiftFormulaConverter). That
    /// merge is stood in for here, so this test checks exactly what the file owes: every
    /// other required key in `swift.compiler`.
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
    /// toolDescriptor field, and all of those come from the file.
    func test_swiftPackageReaderNamespaceSatisfiesSwiftPackageReaderConfiguration() throws {
        try forEachConfigFile(namespace: SwiftPackageReaderConfiguration.settingNamespace) { path, settings in
            XCTAssertNoThrow(try SwiftPackageReaderConfiguration(properties: settings), path)
        }
    }
}
