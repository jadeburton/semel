//
//  ConfigFileTests.swift
//  SemelSwiftTests
//
//  `semel.config` — settings dropped anywhere above a package, in the same key=value
//  format the wire already carries, so there is no format to convert between.
//
//  Its reason for existing: a setting like the SDK must reach the graph as an ordinary
//  input. Read from the machine instead, a change to it schedules nothing, so nothing
//  rebuilds and the stale artifact stays published — see B-29.
//
//  Two dimensions of inheritance, one rule for both — most specific wins:
//    across files    a nearer ancestor overrides a further one, per key
//    across tools    swift.compiler.X overrides swift.X, for the compiler
//

@testable import SemelSwift
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class ConfigFileTests: SemelSwiftTestCase {

    private func makeConverter() throws -> SwiftFormulaConverter {
        try SwiftFormulaConverter(thisNode: Node(id: 1, kind: SwiftFormulaConverter.kind))
    }

    private let plainManifest = """
        {
          "name": "pkg",
          "dependencies": [],
          "products": [{"name": "pkg", "targets": ["Lib"], "type": {"library": ["automatic"]}}],
          "targets": [{"name": "Lib", "type": "regular", "path": "Sources/Lib", "dependencies": []}]
        }
        """

    private func convert(packageFolder: String = "input:/pkg",
                         configs: [String: String] = [:]) throws -> ProcessOutput {
        let manifest = FolderManifest(baseFolderPath: packageFolder, entries: [])
        var configValues = [String: NodeValue]()
        for (path, text) in configs {
            configValues[path] = .value(try text.intern())
        }
        return try makeConverter().process(input: ProcessInput(inputValues: [
            SwiftFormulaConverter.packageFolder:        ["folder": .value(try manifest.toJSON().intern())],
            SwiftFormulaConverter.packageJSON:          ["json":   .value(try plainManifest.intern())],
            SwiftFormulaConverter.externalPackageJSONs: [:],
            SwiftFormulaConverter.configFiles:          configValues,
        ]))
    }

    private func formula(_ output: ProcessOutput) throws -> String {
        try XCTUnwrap(output.outputValues[SwiftFormulaConverter.formulaOutput])
            .expectValue().resolveAsString()
    }

    private func infoLog(_ output: ProcessOutput) throws -> String {
        let hash = try XCTUnwrap(output.outputValues[SwiftFormulaConverter.infoLog]).expectValue()
        return hash.isEmpty ? "" : try hash.resolveAsString()
    }

    /// The `Configuration(...)` of one emitted node, so an assertion about the compiler
    /// cannot be satisfied by the linker's configuration or the reverse. Without this the
    /// broadcasting bug these tests exist to prevent would pass every one of them.
    private func compilerConfig(in formula: String) throws -> String {
        try configuration(ofBlockStartingWith: "func compilerLib()", in: formula)
    }

    private func linkerConfig(in formula: String) throws -> String {
        try configuration(ofBlockStartingWith: "product ", in: formula)
    }

    private func configuration(ofBlockStartingWith prefix: String, in formula: String) throws -> String {
        let block = try XCTUnwrap(formula.components(separatedBy: "\n\n").first { $0.hasPrefix(prefix) },
                                  "no '\(prefix)' block in:\n\(formula)")
        let tail = try XCTUnwrap(block.components(separatedBy: "Configuration(").dropFirst().first,
                                 "no Configuration in:\n\(block)")
        return try XCTUnwrap(tail.components(separatedBy: ")").first)
    }

    // MARK: - Where it looks

    /// Asked for at every ancestor, so one file can serve a tree of N packages. The ones
    /// that do not exist are ghosts with no value — which is what makes dropping the file
    /// in later light up the wire and re-run the conversion on its own.
    func test_asksForAConfigFileAtEveryAncestorOfThePackage() throws {
        let output = try convert(packageFolder: "input:/a/b/pkg")
        let asked = try XCTUnwrap(output.inputWireExpectations[SwiftFormulaConverter.configFiles]).keys.sorted()

        XCTAssertEqual(asked, ["input:/a/b/pkg/semel.config",
                               "input:/a/b/semel.config",
                               "input:/a/semel.config",
                               "input:/semel.config"])
    }

    // MARK: - Inheritance across files

    func test_appliesASettingFromAnAncestor() throws {
        let result = try formula(try convert(
            packageFolder: "input:/a/b/pkg",
            configs: ["input:/a/semel.config": "swift.sdkVersion=26.5"]))

        XCTAssertTrue(try compilerConfig(in: result).contains("sdkVersion: '26.5'"), "got:\n\(result)")
    }

    /// Nearest wins per *key*, so a nearer file overriding one setting does not discard the
    /// rest — which is what makes these inheritable rather than all-or-nothing.
    func test_theNearestAncestorWinsPerKey() throws {
        let result = try formula(try convert(
            packageFolder: "input:/a/b/pkg",
            configs: ["input:/semel.config":         "swift.sdkVersion=1.0\nswift.toolDescriptor.name=fromRoot",
                      "input:/a/b/pkg/semel.config": "swift.sdkVersion=26.5"]))
        let compiler = try compilerConfig(in: result)

        XCTAssertTrue(compiler.contains("sdkVersion: '26.5'"), "nearest wins, got:\n\(compiler)")
        XCTAssertTrue(compiler.contains("toolDescriptor.name: 'fromRoot'"),
                      "a key only the further file sets is still inherited, got:\n\(compiler)")
    }

    // MARK: - Inheritance across tools

    /// An unqualified setting is the default for every Swift tool — this is what makes a
    /// master config of defaults possible.
    func test_anUnqualifiedSettingReachesEveryTool() throws {
        let result = try formula(try convert(configs: ["input:/semel.config": "swift.sdkVersion=26.5"]))

        XCTAssertTrue(try compilerConfig(in: result).contains("sdkVersion: '26.5'"), "got:\n\(result)")
        XCTAssertTrue(try linkerConfig(in: result).contains("sdkVersion: '26.5'"), "got:\n\(result)")
    }

    func test_aToolQualifiedSettingOverridesTheDefaultForThatToolOnly() throws {
        let result = try formula(try convert(configs: ["input:/semel.config":
            "swift.sdkVersion=26.5\nswift.compiler.sdkVersion=26.6"]))

        XCTAssertTrue(try compilerConfig(in: result).contains("sdkVersion: '26.6'"), "got:\n\(result)")
        XCTAssertTrue(try linkerConfig(in: result).contains("sdkVersion: '26.5'"),
                      "the linker keeps the default, got:\n\(result)")
    }

    /// The reason tool namespaces exist: a setting reaches the node it names and nothing
    /// else. Broadcasting every setting to every node put properties on nodes that ignore
    /// them — and a node's properties are its identity and part of its cache key, so an
    /// ignored setting still recreated the node and orphaned its cached output.
    func test_aToolQualifiedSettingDoesNotReachOtherTools() throws {
        let result = try formula(try convert(configs: ["input:/semel.config":
            "swift.linker.sdkVersion=26.6"]))

        XCTAssertFalse(try compilerConfig(in: result).contains("sdkVersion"),
                       "a linker setting must not touch the compiler's identity, got:\n\(result)")
        XCTAssertTrue(try linkerConfig(in: result).contains("sdkVersion: '26.6'"), "got:\n\(result)")
    }

    /// A dotted key whose first part is not a tool name is just a key. `toolDescriptor.*`
    /// has to keep working, or pinning a compiler version becomes impossible.
    func test_aDottedKeyThatIsNotAToolNameIsJustAKey() throws {
        let output = try convert(configs: ["input:/semel.config": "swift.toolDescriptor.version=pinned"])

        XCTAssertTrue(try compilerConfig(in: try formula(output)).contains("toolDescriptor.version: 'pinned'"))
        XCTAssertEqual(try infoLog(output), "", "it is a real setting, not a mistake")
    }

    // MARK: - Keys a tool does not accept

    /// Each tool declares what a file may set; everything else is dropped and *reported*.
    /// Silently ignoring it is the least helpful outcome, and letting it through would put
    /// a meaningless property into the node's identity.
    func test_aKeyTheToolDoesNotAcceptIsDroppedAndReported() throws {
        let output = try convert(configs: ["input:/semel.config": "swift.compiler.moduleName=Hijacked"])
        let result = try formula(output)

        XCTAssertTrue(try compilerConfig(in: result).contains("moduleName: 'Lib'"), "got:\n\(result)")
        XCTAssertFalse(result.contains("Hijacked"), "got:\n\(result)")
        let report = try infoLog(output)
        XCTAssertTrue(report.contains("swift.compiler.moduleName"),
                      "the user must be told, got: \(report)")
    }

    /// moduleName comes from the manifest, so no tool accepts it — including one that never
    /// computes it, where it would otherwise land unopposed on the node's identity.
    func test_aManifestSuppliedKeyIsRejectedForEveryTool() throws {
        let output = try convert(configs: ["input:/semel.config": "swift.linker.moduleName=Hijacked"])

        let report = try infoLog(output)
        XCTAssertFalse(try formula(output).contains("Hijacked"))
        XCTAssertTrue(report.contains("comes from the package manifest"),
                      "and told why, got: \(report)")
    }

    /// Unqualified means "a default for every tool", so it is a mistake only when no tool at
    /// all would take it — otherwise a compiler-only default would be reported by the linker.
    func test_anUnknownUnqualifiedKeyIsReported() throws {
        let output = try convert(configs: ["input:/semel.config": "swift.noSuchSetting=1"])

        let report = try infoLog(output)
        XCTAssertFalse(try formula(output).contains("noSuchSetting"))
        XCTAssertTrue(report.contains("swift.noSuchSetting"), "got: \(report)")
    }

    func test_theReportNamesTheFileThatSetIt() throws {
        let output = try convert(packageFolder: "input:/a/pkg",
                                 configs: ["input:/a/semel.config": "swift.noSuchSetting=1"])

        let report = try infoLog(output)
        XCTAssertTrue(report.hasPrefix("input:/a/semel.config:"), "got: \(report)")
    }

    // MARK: - Other namespaces, and none at all

    func test_ignoresSettingsForOtherToolchains() throws {
        let output = try convert(configs: ["input:/semel.config": "clang.target=arm64\nunprefixed=x"])

        XCTAssertFalse(try formula(output).contains("target: 'arm64'"))
        XCTAssertFalse(try formula(output).contains("unprefixed"))
        XCTAssertEqual(try infoLog(output), "", "another toolchain's settings are not ours to reject")
    }

    func test_noConfigFileLeavesTheFormulaAsItWas() throws {
        let output = try convert()

        let result = try formula(output)
        XCTAssertTrue(result.contains("Configuration(moduleName: 'Lib').output"), "got:\n\(result)")
        XCTAssertEqual(try infoLog(output), "")
    }

    /// Comments and blank lines cost nothing: a line with no `=` is already skipped by the
    /// key=value parser, which is one of the reasons not to introduce a second format.
    func test_commentsAndBlankLinesAreIgnored() throws {
        let output = try convert(configs: ["input:/semel.config":
            "# what this tree builds against\n\nswift.sdkVersion=26.5\n"])

        XCTAssertTrue(try compilerConfig(in: try formula(output)).contains("sdkVersion: '26.5'"))
        XCTAssertEqual(try infoLog(output), "", "a comment is not an unknown setting")
    }
}

// MARK: - Honouring a declared SDK

final class DeclaredSDKTests: SemelSwiftTestCase {

    /// A declared version that matches the machine is simply accepted.
    func test_aMatchingDeclaredSDKIsAccepted() throws {
        let actual = try XCTUnwrap(resolveSDKVersion(), "this machine has no macOS SDK")

        XCTAssertNoThrow(try verifySDKVersion(actual))
    }

    /// Nothing declared means the machine's SDK, which is how every existing tree behaves.
    func test_declaringNothingIsAccepted() {
        XCTAssertNoThrow(try verifySDKVersion(nil))
    }

    /// Loud rather than accommodating. Silently compiling against a different SDK than the
    /// one recorded is how two machines produce different artifacts that look identical.
    func test_aMismatchedDeclaredSDKFailsAndNamesBoth() throws {
        let actual = try XCTUnwrap(resolveSDKVersion())

        XCTAssertThrowsError(try verifySDKVersion("0.1")) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("0.1"), "should name what was declared, got \(message)")
            XCTAssertTrue(message.contains(actual), "should name what the machine has, got \(message)")
        }
    }
}
