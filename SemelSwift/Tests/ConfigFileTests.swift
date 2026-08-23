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

    private func convert(packageFolder: String,
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

    private func configExpectations(_ output: ProcessOutput) throws -> [String] {
        try XCTUnwrap(output.inputWireExpectations[SwiftFormulaConverter.configFiles]).keys.sorted()
    }

    // MARK: - Where it looks

    /// Asked for at every ancestor, so one file can serve a tree of N packages. The ones
    /// that do not exist are ghosts with no value — which is what makes dropping the file
    /// in later light up the wire and re-run the conversion on its own.
    func test_asksForAConfigFileAtEveryAncestorOfThePackage() throws {
        let output = try convert(packageFolder: "input:/a/b/pkg")

        XCTAssertEqual(try configExpectations(output),
                       ["input:/a/b/pkg/semel.config",
                        "input:/a/b/semel.config",
                        "input:/a/semel.config",
                        "input:/semel.config"])
    }

    // MARK: - What it applies

    func test_appliesASettingFromAnAncestor() throws {
        let result = try formula(try convert(
            packageFolder: "input:/a/b/pkg",
            configs: ["input:/a/semel.config": "swift.sdkVersion=26.5"]))

        XCTAssertTrue(result.contains("sdkVersion: '26.5'"), "got:\n\(result)")
    }

    /// Nearest wins, per key — the rule that makes these inheritable without anyone having
    /// to decide what merging a nested object means.
    func test_theNearestAncestorWinsPerKey() throws {
        let result = try formula(try convert(
            packageFolder: "input:/a/b/pkg",
            configs: ["input:/semel.config":        "swift.sdkVersion=1.0\nswift.other=root",
                      "input:/a/b/pkg/semel.config": "swift.sdkVersion=26.5"]))

        XCTAssertTrue(result.contains("sdkVersion: '26.5'"), "nearest should win, got:\n\(result)")
        XCTAssertTrue(result.contains("other: 'root'"),
                      "a key only the further file sets is still inherited, got:\n\(result)")
    }

    /// The file spans toolchains, so it is namespaced; a node's own configuration is
    /// already scoped to a Swift compile, so the namespace comes off.
    func test_stripsTheSwiftNamespaceAndIgnoresOthers() throws {
        let result = try formula(try convert(
            packageFolder: "input:/pkg",
            configs: ["input:/semel.config": "swift.sdkVersion=26.5\nclang.target=arm64\nunprefixed=x"]))

        XCTAssertTrue(result.contains("sdkVersion: '26.5'"), "got:\n\(result)")
        XCTAssertFalse(result.contains("target: 'arm64'"), "clang settings are not ours, got:\n\(result)")
        XCTAssertFalse(result.contains("unprefixed"), "got:\n\(result)")
    }

    /// The manifest owns what the targets *are*; the file owns the environment they are
    /// built in. So a file cannot set moduleName at all — not merely "loses to" it. Simply
    /// letting the derived value win is not enough: the linker derives no moduleName, so
    /// the setting would sail past the override onto the linker's configuration, and from
    /// there into its node identity.
    func test_theFileCannotSetAKeyTheManifestOwns() throws {
        let result = try formula(try convert(
            packageFolder: "input:/pkg",
            configs: ["input:/semel.config": "swift.moduleName=Hijacked"]))

        XCTAssertTrue(result.contains("moduleName: 'Lib'"), "got:\n\(result)")
        XCTAssertFalse(result.contains("Hijacked"),
                       "not on the compiler, and not on the linker either, got:\n\(result)")
    }

    func test_noConfigFileLeavesTheFormulaAsItWas() throws {
        let result = try formula(try convert(packageFolder: "input:/pkg"))

        XCTAssertTrue(result.contains("Configuration(moduleName: 'Lib').output"), "got:\n\(result)")
    }

    /// Comments and blank lines cost nothing: a line with no `=` is already skipped by the
    /// key=value parser, which is one of the reasons not to introduce a second format.
    func test_commentsAndBlankLinesAreIgnored() throws {
        let result = try formula(try convert(
            packageFolder: "input:/pkg",
            configs: ["input:/semel.config": "# what this tree builds against\n\nswift.sdkVersion=26.5\n"]))

        XCTAssertTrue(result.contains("sdkVersion: '26.5'"), "got:\n\(result)")
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
