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
        // The target's folder, holding a Swift file: what the converter asks for to tell a
        // C target from a Swift one (B-54).
        let libFolder = FolderManifest(baseFolderPath: "\(packageFolder)/Sources/Lib",
                                       entries: [FolderManifestEntry(name: "Lib.swift", isFolder: false, isPinned: true)])
        let output = try converter.process(input: ProcessInput(inputValues: [
            SwiftFormulaConverter.packageFolder:        ["folder": .value(try manifest.toJSON().intern())],
            SwiftFormulaConverter.packageJSON:          ["json":   .value(try plainManifest.intern())],
            SwiftFormulaConverter.externalPackageJSONs: [:],
            SwiftFormulaConverter.targetFolders:        ["\(packageFolder)/Sources/Lib": .value(try libFolder.toJSON().intern())],
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

    /// The wires a `SwiftFormulaConverter(path: <folder>)` asks for on its first pass, when
    /// a formula's `include` named it and nothing is wired yet.
    private func selfWiring(packageFolder folder: String = "input:/repo/pkg") throws -> [String: [String: GraphSpecNode]] {
        let converter = try SwiftFormulaConverter(thisNode: NodeRecord(id: 1, kind: SwiftFormulaConverter.kind,
                                                                       name: nil, properties: ["path": folder],
                                                                       scheduled: false, identity: nil))
        let output = try converter.process(input: ProcessInput(inputValues: [:]))
        guard case .noValue = try XCTUnwrap(output.outputValues[SwiftFormulaConverter.formulaOutput]) else {
            XCTFail("the first pass has no manifest to convert; it should be pending")
            return [:]
        }
        return output.inputWireSpecs
    }

    func test_theNamedPackagesReaderIsWiredToASelectorForItsOwnNamespace() throws {
        let reader = try XCTUnwrap(try selfWiring()[SwiftFormulaConverter.packageJSON]?.values.first).asString(omitOutputPort: false)

        XCTAssertTrue(reader.contains("ConfigFilter(prefix: 'swift.packageReader'"), "got:\n\(reader)")
        XCTAssertFalse(reader.contains("Configuration().output"),
                       "an empty Configuration leaves the reader with no toolDescriptor, got:\n\(reader)")
    }

    func test_theNamedPackagesReaderReadsTheConfigFileBesideThePackage() throws {
        let specs  = try selfWiring(packageFolder: "input:/repo/pkg")
        let reader = try XCTUnwrap(specs[SwiftFormulaConverter.packageJSON]?["input:/repo/pkg/Package.swift"]).asString(omitOutputPort: false)

        XCTAssertTrue(reader.contains("StaticFile(path: 'input:/repo/pkg/semel.config')"), "got:\n\(reader)")
        XCTAssertEqual(specs[SwiftFormulaConverter.packageFolder]?.rendered,
                       ["input:/repo/pkg": "Folder(path: 'input:/repo/pkg').manifest"])
    }

    /// Wired explicitly instead of by path, the node has no wires of its own to ask for,
    /// and without either it says what it needs.
    func test_withoutAPathAndWithoutWiresTheConverterSaysWhatItNeeds() throws {
        let converter = try SwiftFormulaConverter(thisNode: NodeRecord(id: 1, kind: SwiftFormulaConverter.kind))

        XCTAssertThrowsError(try converter.process(input: ProcessInput(inputValues: [:]))) { error in
            XCTAssertTrue(String(describing: error).contains("path"), "got \(error)")
        }
    }

    /// B-10: a Package.swift on its own creates no builder. A formula names the package —
    /// `include SwiftFormulaConverter(path: <.>).formula` — and nothing is registered as a
    /// project kind for `Package.swift`.
    func test_aPackageIsNotDiscoveredAsAProjectOfItsOwn() throws {
        try SemelSwift.register()

        let entry = FolderManifestEntry(name: "Package.swift", isFolder: false, isPinned: true)
        for plugin in ProjectDiscovery.plugins {
            XCTAssertNil(plugin.spec(forEntry: entry, inFolder: "input:/repo/pkg"),
                         "\(type(of: plugin)) still claims Package.swift")
        }
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

// MARK: - Choosing the SDK

/// The Swift tools built against the macOS SDK and nothing else. An iOS package needs
/// `swift.compiler.sdk=iphonesimulator` (and a `target` triple), and each SDK has an
/// identity of its own that `sdkVersion` is checked against.
final class SDKChoiceTests: SemelSwiftTestCase {

    func test_theDefaultSDKIsMacOS() throws {
        XCTAssertEqual(defaultSDKName, "macosx")
        XCTAssertEqual(resolveSDKVersion(), resolveSDKVersion(sdk: "macosx"))
        XCTAssertEqual(resolveSDKPath(), resolveSDKPath(sdk: "macosx"))
    }

    func test_eachSDKHasItsOwnIdentityAndPath() throws {
        let macOS     = try XCTUnwrap(resolveSDKVersion(sdk: "macosx"))
        let simulator = try XCTUnwrap(resolveSDKVersion(sdk: "iphonesimulator"), "Xcode ships the simulator SDK")

        XCTAssertNotEqual(macOS, simulator, "different SDKs are different builds")
        XCTAssertTrue(try XCTUnwrap(resolveSDKPath(sdk: "iphonesimulator")).contains("iPhoneSimulator"))
    }

    /// The declared version is checked against the declared SDK, not against macOS.
    func test_theVersionCheckIsAgainstTheDeclaredSDK() throws {
        let simulator = try XCTUnwrap(resolveSDKVersion(sdk: "iphonesimulator"))

        XCTAssertNoThrow(try verifySDKVersion(simulator, sdk: "iphonesimulator"))
        XCTAssertThrowsError(try verifySDKVersion(simulator, sdk: "macosx"))
    }

    func test_anUnknownSDKNameIsNamedInTheFailure() {
        XCTAssertNil(resolveSDKPath(sdk: "nonesuch"))
        XCTAssertThrowsError(try verifySDKVersion("1.0 (1A1)", sdk: "nonesuch")) { error in
            XCTAssertTrue(String(describing: error).contains("nonesuch"), "got \(error)")
        }
    }
}

// MARK: - The language mode

/// `.swiftLanguageMode(.v6)` on a target becomes `-swift-version 6`. The converter carries it
/// as a manifest-derived literal (`languageMode`); nothing declared emits no flag, which keeps
/// every existing tree building the arguments it built before.
final class LanguageModeTests: SemelSwiftTestCase {

    func test_nothingDeclaredEmitsNoFlag() throws {
        XCTAssertNil(try swiftLanguageModeVersion(nil))
    }

    func test_aDeclaredModeIsPassedThrough() throws {
        XCTAssertEqual(try swiftLanguageModeVersion("6"), "6")
        XCTAssertEqual(try swiftLanguageModeVersion("5"), "5")
    }

    func test_anUnknownModeIsRejectedNamingTheChoices() {
        XCTAssertThrowsError(try swiftLanguageModeVersion("7")) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("7"), "got \(message)")
            XCTAssertTrue(message.contains("6"), "should list what is accepted, got \(message)")
        }
    }
}
