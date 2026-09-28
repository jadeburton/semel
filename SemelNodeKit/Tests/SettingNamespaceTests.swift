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
            Missing configuration. Add these to the project's semel.config, with your values:

            clang.linker.target=…
            """)
    }

    /// The toolchain's own identity has one correct spelling, which the machine file holds.
    /// Listing those keys with `=…` would invite the reader to invent it.
    func test_missingToolDescriptorKeysNameTheMachineFileInsteadOfAPlaceholder() {
        var settings = RequiredSettings(properties: [:], namespace: "unregistered.linker")
        _ = ToolDescriptor(required: &settings, properties: [:])

        XCTAssertEqual(messageFrom(settings), """
            Missing machine settings. They belong in semel.machine.config, with the tool descriptors \
            and SDK facts of the tools installed here, these among them:

            unregistered.linker.toolDescriptor.architecture
            unregistered.linker.toolDescriptor.name
            unregistered.linker.toolDescriptor.platform
            unregistered.linker.toolDescriptor.version
            """)
    }

    /// B-119. Which command writes the machine file is the toolchain's to say: the report
    /// names the one its namespace registered, and the core names none of its own.
    func test_missingMachineSettingsNameTheCommandTheToolchainRegistered() {
        ToolNamespaceRegistry.register(.init(namespace: "writer.linker", toolName: "clang",
                                             machineFileWriter: .init(command: "semel-clang", rewriteFlags: ["--force"])))
        var settings = RequiredSettings(properties: [:], namespace: "writer.linker")
        _ = settings.value("toolDescriptor.name")

        XCTAssertEqual(messageFrom(settings), """
            Missing machine settings. Run 'semel-clang <folder>': it writes semel.machine.config with the tool \
            descriptors and SDK facts of the tools installed here, these among them:

            writer.linker.toolDescriptor.name
            """)
    }

    /// B-109. A key the namespace declares as a machine setting is the machine's to answer,
    /// like the tool descriptor, and is listed with it rather than as a choice.
    func test_aMissingDeclaredMachineSettingIsListedWithTheToolDescriptorKeys() {
        ToolNamespaceRegistry.register(.init(namespace: "clang.linker", toolName: "clang",
                                             machineSettingKeys: ["sdkPath"]))
        var settings = RequiredSettings(properties: [:], namespace: "clang.linker")
        _ = settings.value("sdkPath")
        _ = settings.value("target")

        let message = messageFrom(settings)
        XCTAssertTrue(message.contains("clang.linker.target=…"), message)
        XCTAssertTrue(message.contains("\nclang.linker.sdkPath"), message)
        XCTAssertFalse(message.contains("sdkPath=…"), message)
    }

    /// Both kinds at once is the common case — a fresh config file has neither — and the
    /// two lists stay apart so the placeholders mark only the open questions.
    func test_choicesAndToolDescriptorKeysAreListedSeparately() {
        var settings = RequiredSettings(properties: [:], namespace: "clang.linker")
        _ = settings.value("target")
        _ = settings.value("toolDescriptor.name")

        let message = messageFrom(settings)
        XCTAssertTrue(message.contains("clang.linker.target=…"), message)
        XCTAssertTrue(message.contains("\nclang.linker.toolDescriptor.name"), message)
        XCTAssertFalse(message.contains("toolDescriptor.name=…"), message)
        XCTAssertTrue(message.contains("Missing machine settings."), message)
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
