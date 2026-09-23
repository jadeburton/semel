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
        XCTAssertEqual(derivedSettingNamespace(forTypeName: "SwiftCompiler"), "swift.compiler")
        XCTAssertEqual(derivedSettingNamespace(forTypeName: "SwiftLinker"), "swift.linker")
        XCTAssertEqual(derivedSettingNamespace(forTypeName: "ClangPreprocessor"), "clang.preprocessor")
    }

    /// A multi-word remainder stays one segment, lower-camelled — the namespace has exactly two
    /// levels above the key, so `swift.package.reader` would put a package domain in the file.
    func test_aMultiWordRemainderIsOneLowerCamelSegment() {
        XCTAssertEqual(derivedSettingNamespace(forTypeName: "SwiftPackageReader"), "swift.packageReader")
        XCTAssertEqual(derivedSettingNamespace(forTypeName: "SwiftFormulaConverter"), "swift.formulaConverter")
    }

    /// A trailing `Tool` says nothing about what the node is for.
    func test_aTrailingToolIsDropped() {
        XCTAssertEqual(derivedSettingNamespace(forTypeName: "ClangLinker"), "clang.linker")
    }

    /// A single-word type has no domain to give, which is the signal its name is wrong rather
    /// than something to paper over — see ClangIncludeFinder.
    func test_aSingleWordTypeGivesOnlyADomain() {
        XCTAssertEqual(derivedSettingNamespace(forTypeName: "Configuration"), "configuration")
    }

    /// A run of capitals is treated as one word. This matters because the derived namespace
    /// becomes a config-file prefix that users type, so `swift.http` (not `swift.hTTP`) is
    /// what belongs in a file.
    func test_aRunOfCapitalsIsOneWord() {
        XCTAssertEqual(derivedSettingNamespace(forTypeName: "SwiftHTTPTool"), "swift.http")
        XCTAssertEqual(derivedSettingNamespace(forTypeName: "SwiftHTTPClientTool"), "swift.httpClient")
        XCTAssertEqual(derivedSettingNamespace(forTypeName: "HTTPTool"), "http")
        XCTAssertEqual(derivedSettingNamespace(forTypeName: "ABTool"), "ab")
    }

    // MARK: - What a missing key tells the reader

    /// The keys a project has to decide for itself get `=…`, the place its answer goes.
    func test_aMissingChoiceIsListedWithAPlaceholder() {
        var settings = RequiredSettings(properties: [:], namespace: "clang.linker")
        _ = settings.value("target")

        XCTAssertEqual(messageFrom(settings), """
            Missing configuration. Add these to a semel.config in the input file system:

            clang.linker.target=…
            """)
    }

    /// The toolchain's own identity has one correct spelling, which `tools` prints. Listing
    /// those keys with `=…` would invite the reader to invent it.
    func test_missingToolDescriptorKeysNameTheToolsCommandInsteadOfAPlaceholder() {
        var settings = RequiredSettings(properties: [:], namespace: "clang.linker")
        _ = ToolDescriptor(required: &settings, properties: [:])

        XCTAssertEqual(messageFrom(settings), """
            Missing configuration. Add these to a semel.config in the input file system:

            clang.linker.toolDescriptor.architecture
            clang.linker.toolDescriptor.name
            clang.linker.toolDescriptor.platform
            clang.linker.toolDescriptor.version

            Run 'tools clang.linker' for those: it prints the clang.linker.toolDescriptor \
            settings of the tool installed on this machine, as a block to paste.
            """)
    }

    /// Both kinds at once is the common case — a fresh config file has neither — and the
    /// two lists stay apart so the placeholders mark only the open questions.
    func test_choicesAndToolDescriptorKeysAreListedSeparately() {
        var settings = RequiredSettings(properties: [:], namespace: "clang.linker")
        _ = settings.value("target")
        _ = settings.value("toolDescriptor.name")

        let message = messageFrom(settings)
        XCTAssertTrue(message.contains("clang.linker.target=…"), message)
        XCTAssertTrue(message.contains("\nclang.linker.toolDescriptor.name\n"), message)
        XCTAssertFalse(message.contains("toolDescriptor.name=…"), message)
        XCTAssertTrue(message.contains("Run 'tools clang.linker'"), message)
    }

    /// The message reads as its own words rather than as the enum case wrapping it: that
    /// is what lets the terminal print it as an indented block of pasteable lines.
    private func messageFrom(_ settings: RequiredSettings) -> String {
        do {
            try settings.check()
            XCTFail("expected a missing-configuration error")
            return ""
        } catch {
            return "\(error)"
        }
    }
}
