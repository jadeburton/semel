//
//  ProjectBuilderTests.swift
//  build_system_tests
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
                        properties: properties, scheduled: false, searchKey: nil)
        let builder = try ProjectBuilder(thisNode: node)
        let input = ProcessInput(inputValues: [
            ProjectBuilder.projectFileInputPort:  [projectFile: .value(try (formula ?? oneProduct).intern())],
            ProjectBuilder.productInputPort:      [:],
            ProjectBuilder.foldersInputPort:      [:],
            ProjectBuilder.graphImportsInputPort: [:],
        ])
        let output = try builder.process(input: input)
        return try XCTUnwrap(output.inputWireExpectations[ProjectBuilder.productInputPort]).keys.sorted()
    }

    // MARK: - Product placement

    /// SwiftPackagePlugin keys the projectFile wire by the package *folder*, so deriving
    /// the output location from the wire key's parent put products one level too high:
    /// the root package's `build_system` product landed on `output:/swift/build_system`,
    /// the very folder holding the nested packages' products.
    func test_placesAPackageProductInsideThePackageFolder() throws {
        let paths = try productPaths(projectFile: "input:/swift/build_system",
                                     properties: ["outputFolder": "input:/swift/build_system"])

        XCTAssertEqual(paths, ["output:/swift/build_system/MyProduct"])
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
}
