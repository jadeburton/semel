//
//  ConfigFileTests.swift
//  SemelSwiftTests
//
//  What the converter emits so a compiled target receives its settings.
//
//  The settings themselves are not the converter's business any more. It names a file and a
//  namespace; what the file says arrives later, on a wire, and never enters a graphSpec — which
//  is what lets a setting change without recreating every node that reads it.
//

@testable import SemelSwift
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class ConfigFileTests: SemelSwiftTestCase {

    private let plainManifest = """
        {
          "name": "pkg",
          "dependencies": [],
          "products": [{"name": "pkg", "targets": ["Lib"], "type": {"library": ["automatic"]}}],
          "targets": [{"name": "Lib", "type": "regular", "path": "Sources/Lib", "dependencies": []}]
        }
        """

    private func formula(packageFolder: String = "input:/pkg") throws -> String {
        let manifest = FolderManifest(baseFolderPath: packageFolder, entries: [])
        let converter = try SwiftFormulaConverter(thisNode: NodeRecord(id: 1, kind: SwiftFormulaConverter.kind))
        let output = try converter.process(input: ProcessInput(inputValues: [
            SwiftFormulaConverter.packageFolder:        ["folder": .value(try manifest.toJSON().intern())],
            SwiftFormulaConverter.packageJSON:          ["json":   .value(try plainManifest.intern())],
            SwiftFormulaConverter.externalPackageJSONs: [:],
        ]))
        return try XCTUnwrap(output.outputValues[SwiftFormulaConverter.formulaOutput])
            .expectValue().resolveAsString()
    }

    /// The compiler's settings arrive through a selector naming the compiler's namespace, not
    /// as literals the converter resolved.
    func test_theCompilerIsWiredToASelectorForItsOwnNamespace() throws {
        let result = try formula()

        XCTAssertTrue(result.contains("ConfigFilter(prefix: 'swift.compiler'"), "got:\n\(result)")
    }

    func test_theLinkerIsWiredToASelectorForItsOwnNamespace() throws {
        let result = try formula()

        XCTAssertTrue(result.contains("ConfigFilter(prefix: 'swift.linker'"), "got:\n\(result)")
    }

    /// The selector reads the config file from the package folder, named in the spec so the
    /// wire exists whether or not the file has been pushed yet.
    func test_theSelectorReadsTheConfigFileBesideThePackage() throws {
        let result = try formula(packageFolder: "input:/a/pkg")

        XCTAssertTrue(result.contains("StaticFile(path: 'input:/a/pkg/semel.config')"), "got:\n\(result)")
    }

    /// Manifest-derived values stay literals: they say what the target *is*, so they belong in
    /// identity. Settings do not appear here at all.
    func test_theManifestStillSuppliesModuleNameAsALiteral() throws {
        let result = try formula()

        XCTAssertTrue(result.contains("moduleName: 'Lib'"), "got:\n\(result)")
        XCTAssertFalse(result.contains("sdkVersion:"),
                       "a setting must not be rendered as a property, got:\n\(result)")
    }
}

// MARK: - The first node of every build

/// `SwiftPackagePlugin` writes the graph spec for a discovered `Package.swift`, and the
/// reader it names is the node everything else waits on. Nothing defaults, so a reader with
/// no `toolDescriptor` fails the build before the manifest is even parsed.
final class PackagePluginConfigTests: SemelSwiftTestCase {

    private func spec(entry: String = "Package.swift",
                       inFolder folder: String = "input:/repo/pkg") throws -> String {
        let plugin = SwiftPackagePlugin()
        let manifestEntry = FolderManifestEntry(name: entry, isFolder: false, isPinned: true)
        return try XCTUnwrap(plugin.specString(forEntry: manifestEntry, inFolder: folder),
                             "the plugin should claim \(entry)")
    }

    func test_theDiscoveredPackagesReaderIsWiredToASelectorForItsOwnNamespace() throws {
        let result = try spec()

        XCTAssertTrue(result.contains("ConfigFilter(prefix: 'swift.packageReader'"), "got:\n\(result)")
        XCTAssertFalse(result.contains("Configuration().output"),
                       "an empty Configuration leaves the reader with no toolDescriptor, got:\n\(result)")
    }

    func test_theDiscoveredPackagesReaderReadsTheConfigFileBesideThePackage() throws {
        let result = try spec(inFolder: "input:/repo/pkg")

        XCTAssertTrue(result.contains("StaticFile(path: 'input:/repo/pkg/semel.config')"), "got:\n\(result)")
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

    // B-47, the narrow part. A version string alone (`26.5`) cannot tell two builds of one
    // SDK apart, so two machines could pass the check and still compile against different
    // headers. The identity the machine reports, and the one a config has to declare, is
    // the version together with the SDK build number: `26.5 (25F70)`.

    func test_theMachineSDKIdentityCarriesTheBuildNumber() throws {
        let actual = try XCTUnwrap(resolveSDKVersion())

        let form = try NSRegularExpression(pattern: #"^[0-9]+(\.[0-9]+)* \([0-9A-Za-z]+\)$"#)
        XCTAssertNotNil(form.firstMatch(in: actual, range: NSRange(actual.startIndex..., in: actual)),
                        "expected `<version> (<build>)`, got \(actual)")
    }

    /// The old form is not quietly accepted as a partial match: it fails, and the message
    /// hands over the exact string to declare instead.
    func test_aVersionWithoutABuildNumberIsRejectedAndToldTheFullForm() throws {
        let actual  = try XCTUnwrap(resolveSDKVersion())
        let version = String(actual.prefix { $0 != " " })

        XCTAssertThrowsError(try verifySDKVersion(version)) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains(actual), "should give the full form to paste, got \(message)")
            XCTAssertTrue(message.lowercased().contains("build"), "should say the build number is part of it, got \(message)")
        }
    }
}
