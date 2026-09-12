//
//  ProjectBuilderTests.swift
//  semel_tests
//
//  Where a project's products land in the output file system. The rule is not obvious
//  because the two ProjectFinder plugins wire their projectFile port differently: a
//  Swift package is keyed by its *folder*, a .fmla project by the *file*.
//

@testable import SemelCore
import XCTest
import SemelNodeKit

final class ProjectBuilderTests: SemelCoreTestCase {

    // MARK: - Helpers

    /// One product, wired to a node that needs nothing — the product's shape is
    /// irrelevant here, only the output path it is wrapped in.
    private let oneProduct = """
        product 'MyProduct' =
            Configuration(moduleName: 'X').output
        """

    private func productPaths(projectFile: String,
                              properties: [String: String] = [:],
                              formula: String? = nil) throws -> [String] {
        let node = NodeRecord(id: 1, kind: ProjectBuilder.kind, name: nil,
                        properties: properties, scheduled: false, graphSpec: nil)
        let builder = try ProjectBuilder(thisNode: node)
        let input = ProcessInput(inputValues: [
            ProjectBuilder.projectFileInputPort:  [projectFile: .value(try (formula ?? oneProduct).intern())],
            ProjectBuilder.productInputPort:      [:],
            ProjectBuilder.foldersInputPort:      [:],
            ProjectBuilder.graphImportsInputPort: [:],
        ])
        let output = try builder.process(input: input)
        return try XCTUnwrap(output.inputWireSpecs[ProjectBuilder.productInputPort]).keys.sorted()
    }

    // MARK: - Product placement

    /// SwiftPackagePlugin keys the projectFile wire by the package *folder*, so deriving
    /// the output location from the wire key's parent put products one level too high:
    /// the root package's `semel` product landed on `output:/swift/semel`,
    /// the very folder holding the nested packages' products.
    func test_placesAPackageProductInsideThePackageFolder() throws {
        let paths = try productPaths(projectFile: "input:/swift/semel",
                                     properties: ["outputFolder": "input:/swift/semel"])

        XCTAssertEqual(paths, ["output:/swift/semel/MyProduct"])
    }

    /// FormulaFilePlugin keys the wire by the .fmla file itself, whose containing folder
    /// is the project's own directory — so this placement is unchanged.
    func test_placesAFormulaFileProductBesideTheFormulaFile() throws {
        let paths = try productPaths(projectFile: "input:/proj/build.fmla",
                                     properties: ["outputFolder": "input:/proj"])

        XCTAssertEqual(paths, ["output:/proj/MyProduct"])
    }

    /// A node created before the property existed must keep working rather than write its
    /// products to the file-system root.
    func test_fallsBackToTheProjectFilesFolderWhenNoOutputFolderIsSet() throws {
        let paths = try productPaths(projectFile: "input:/proj/build.fmla")

        XCTAssertEqual(paths, ["output:/proj/MyProduct"])
    }

    /// Two packages nested one inside the other are the case that collided. Their
    /// products must land on distinct paths, and neither may be a prefix of the other.
    func test_nestedPackagesProduceNonCollidingProductPaths() throws {
        let outer = try productPaths(projectFile: "input:/repo",
                                     properties: ["outputFolder": "input:/repo"],
                                     formula: "product 'repo' =\n    Configuration(moduleName: 'X').output")
        let inner = try productPaths(projectFile: "input:/repo/Core",
                                     properties: ["outputFolder": "input:/repo/Core"],
                                     formula: "product 'Core' =\n    Configuration(moduleName: 'X').output")

        XCTAssertEqual(outer, ["output:/repo/repo"])
        XCTAssertEqual(inner, ["output:/repo/Core/Core"])
        XCTAssertFalse(inner[0].hasPrefix(outer[0] + "/"),
                       "the outer product must not be a folder on the inner product's path")
    }

    // MARK: - A formula that names a package (B-10)

    /// Stands in for the Swift toolchain: the spec of a node whose output is the package's
    /// formula. Here a Configuration, so the spec parses without a real converter.
    private struct StubPackageFormulaProvider: PackageFormulaProvider {
        func formulaSpec(forPackageFolder folder: String) -> String {
            "Configuration(role: 'formula of \(folder)').output"
        }
    }

    private func process(formula: String,
                         packageFormulas: [String: NodeValue] = [:]) throws -> ProcessOutput {
        let node = NodeRecord(id: 1, kind: ProjectBuilder.kind, name: nil,
                              properties: ["outputFolder": "input:/repo"], scheduled: false, graphSpec: nil)
        return try ProjectBuilder(thisNode: node).process(input: ProcessInput(inputValues: [
            ProjectBuilder.projectFileInputPort:     ["input:/repo/semel.fmla": .value(try formula.intern())],
            ProjectBuilder.productInputPort:         [:],
            ProjectBuilder.foldersInputPort:         [:],
            ProjectBuilder.graphImportsInputPort:    [:],
            ProjectBuilder.packageFormulasInputPort: packageFormulas,
        ]))
    }

    /// First pass: the package's formula is not on the wire yet, so the builder asks for
    /// it — through the registered provider — and publishes nothing.
    func test_asksTheProviderForThePackagesFormulaBeforePublishingAnything() throws {
        ProjectDiscovery.register(packageFormulaProvider: StubPackageFormulaProvider())

        let output = try process(formula: "package <.>")

        XCTAssertEqual(output.inputWireSpecs[ProjectBuilder.packageFormulasInputPort],
                       ["input:/repo": "Configuration(role: 'formula of input:/repo').output"])
        XCTAssertEqual(output.inputWireSpecs[ProjectBuilder.productInputPort], [:])
    }

    /// Later pass: the formula has arrived, and the package's products are published beside
    /// the formula file — the formula's folder, not somewhere the package chose.
    func test_publishesThePackagesProductsBesideTheFormula() throws {
        ProjectDiscovery.register(packageFormulaProvider: StubPackageFormulaProvider())
        let packageFormula = "product 'libX.a' = Configuration(moduleName: 'X').output"

        let output = try process(formula: "package <.>",
                                 packageFormulas: ["input:/repo": .value(try packageFormula.intern())])

        XCTAssertEqual(try XCTUnwrap(output.inputWireSpecs[ProjectBuilder.productInputPort]).keys.sorted(),
                       ["output:/repo/libX.a"])
    }

    /// A pending value on the wire — the converter is still waiting for a manifest — is the
    /// same as no value: nothing is published, and the wire is kept.
    func test_aPendingPackageFormulaPublishesNothingYet() throws {
        ProjectDiscovery.register(packageFormulaProvider: StubPackageFormulaProvider())

        let output = try process(formula: "package <.>",
                                 packageFormulas: ["input:/repo": .noValue(reason: .pending)])

        XCTAssertEqual(output.inputWireSpecs[ProjectBuilder.productInputPort], [:])
        XCTAssertEqual(output.inputWireSpecs[ProjectBuilder.packageFormulasInputPort]?.keys.sorted(), ["input:/repo"])
    }

    func test_withNoProviderRegisteredTheFormulaFailsNamingThePackage() throws {
        ProjectDiscovery.removeAll()

        XCTAssertThrowsError(try process(formula: "package <.>")) { error in
            XCTAssertTrue(String(describing: error).contains("input:/repo"), "got \(error)")
        }
    }
}
