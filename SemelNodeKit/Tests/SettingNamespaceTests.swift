//
//  SettingNamespaceTests.swift
//  SemelNodeKitTests
//
//  Where a node's settings live in a config file, derived from what the node is called.
//
//  Deriving keeps the two from drifting, and costs one thing worth knowing: a type rename
//  becomes a breaking change to every config file written against it. That is why the derived
//  name is a default a type can override rather than a rule it cannot escape.
//

@testable import SemelNodeKit
import XCTest

final class SettingNamespaceTests: XCTestCase {

    func test_theFirstWordIsTheDomainAndTheRestIsTheNode() {
        XCTAssertEqual(derivedSettingNamespace(forTypeName: "SwiftCompilerTool"), "swift.compiler")
        XCTAssertEqual(derivedSettingNamespace(forTypeName: "SwiftLinkerTool"), "swift.linker")
        XCTAssertEqual(derivedSettingNamespace(forTypeName: "ClangPreprocessorTool"), "clang.preprocessor")
    }

    /// A multi-word remainder stays one segment, lower-camelled — the namespace has exactly two
    /// levels above the key, so `swift.package.reader` would put a package domain in the file.
    func test_aMultiWordRemainderIsOneLowerCamelSegment() {
        XCTAssertEqual(derivedSettingNamespace(forTypeName: "SwiftPackageReaderTool"), "swift.packageReader")
        XCTAssertEqual(derivedSettingNamespace(forTypeName: "SwiftFormulaConverter"), "swift.formulaConverter")
    }

    /// A trailing `Tool` says nothing about what the node is for.
    func test_aTrailingToolIsDropped() {
        XCTAssertEqual(derivedSettingNamespace(forTypeName: "ClangLinkerTool"), "clang.linker")
    }

    /// A single-word type has no domain to give, which is the signal its name is wrong rather
    /// than something to paper over — see ClangIncludeFinder.
    func test_aSingleWordTypeGivesOnlyADomain() {
        XCTAssertEqual(derivedSettingNamespace(forTypeName: "Configuration"), "configuration")
    }
}
