//
//  SelfBuildConfigTests.swift
//  SemelSwiftTests
//
//  Guards this repository's own semel.config against what its Swift tools actually
//  require. Nothing defaults any more, so the moment one of the six RequiredSettings
//  types grows a new key, every self-build fails until someone edits the file by hand --
//  this is what makes that discovery happen here, in CI, instead of on whoever next
//  tries to build this tree with Semel.
//

@testable import SemelSwift
import Foundation
import SemelNodeKit
import XCTest

final class SelfBuildConfigTests: SemelSwiftTestCase {

    /// The repository root, found relative to this file rather than the working
    /// directory: `swift test` runs from the package folder, not the repo root that
    /// `semel.config` actually lives in.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // SemelSwift
            .deletingLastPathComponent()   // build_system
    }

    private func loadConfig() throws -> [String: String] {
        let path = Self.repositoryRoot.appendingPathComponent("semel.config").path
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return [String: String](plainText: text)
    }

    /// Selects one namespace out of the whole file, stripping the prefix exactly the way
    /// `ConfigSubset` does: a whole dot-delimited segment, not a raw string prefix, so
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

    /// `moduleName` is not in the file -- it reaches the real node as a manifest-derived
    /// literal, merged in beside the selector's output (see SwiftFormulaConverter). That
    /// merge is stood in for here, so this test checks exactly what the file owes: every
    /// other required key in `swift.compiler`.
    func test_swiftCompilerNamespaceSatisfiesSwiftCompilerToolConfiguration() throws {
        let settings = subset(try loadConfig(), under: "swift.compiler")
            .mergedWith(["moduleName": "Test"])

        XCTAssertNoThrow(try SwiftCompilerToolConfiguration(properties: settings))
    }

    /// Same reasoning as the compiler above, but for `outputName`, the linker's own
    /// manifest-derived literal.
    func test_swiftLinkerNamespaceSatisfiesSwiftLinkerToolConfiguration() throws {
        let settings = subset(try loadConfig(), under: "swift.linker")
            .mergedWith(["outputName": "Test"])

        XCTAssertNoThrow(try SwiftLinkerToolConfiguration(properties: settings))
    }

    /// No literals here: every setting `SwiftPackageReaderToolConfiguration` requires is a
    /// toolDescriptor field, and all of those come from the file.
    func test_swiftPackageReaderNamespaceSatisfiesSwiftPackageReaderToolConfiguration() throws {
        let settings = subset(try loadConfig(), under: "swift.packageReader")

        XCTAssertNoThrow(try SwiftPackageReaderToolConfiguration(properties: settings))
    }
}
