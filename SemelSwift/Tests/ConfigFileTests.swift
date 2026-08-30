//
//  ConfigFileTests.swift
//  SemelSwiftTests
//
//  What the converter emits so a compiled target receives its settings.
//
//  The settings themselves are not the converter's business any more. It names a file and a
//  namespace; what the file says arrives later, on a wire, and never enters a searchKey — which
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
        let converter = try SwiftFormulaConverter(thisNode: Node(id: 1, kind: SwiftFormulaConverter.kind))
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

        XCTAssertTrue(result.contains("ConfigSubset(prefix: 'swift.compiler'"), "got:\n\(result)")
    }

    func test_theLinkerIsWiredToASelectorForItsOwnNamespace() throws {
        let result = try formula()

        XCTAssertTrue(result.contains("ConfigSubset(prefix: 'swift.linker'"), "got:\n\(result)")
    }

    /// The selector reads the config file from the package folder, named in the shape so the
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
