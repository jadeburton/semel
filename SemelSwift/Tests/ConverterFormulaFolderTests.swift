//
//  ConverterFormulaFolderTests.swift
//  SemelSwiftTests
//
//  B-143 (b). A formula that names a vendored package by its path and gives no `root:` —
//  `SwiftFormulaConverter(path: <Dependencies/X>)` — has its own folder filled in as the
//  root by its builder (`NodeDescriptor.formulaFolderProperty`), so the converter reads the
//  configuration from beside the formula and never from inside the copy.
//

@testable import SemelSwift
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class ConverterFormulaFolderTests: SemelSwiftTestCase {

    /// The property a builder fills is the one the converter reads its root from.
    func test_theConverterIsGivenTheFormulasFolderAsItsRoot() {
        XCTAssertEqual(SwiftFormulaConverter.descriptor.formulaFolderProperty, SwiftFormulaConverter.rootProperty)
    }

    /// With the formula's folder as its root, the reader of a vendored package's manifest
    /// selects its settings from the formula's `semel.config` and `semel.machine.config`,
    /// and asks for neither inside the package.
    func test_aVendoredPackageNamedByPathReadsTheConfigBesideTheFormula() throws {
        let converter = try SwiftFormulaConverter(thisNode: NodeRecord(
            id: 1, kind: SwiftFormulaConverter.kind, name: nil,
            properties: ["path": "input:/app/Dependencies/X", SwiftFormulaConverter.rootProperty: "input:/app"],
            scheduled: false, identity: nil))

        let output = try converter.process(input: ProcessInput(inputValues: [:]))

        let reader = try XCTUnwrap(output.inputWireSpecs[SwiftFormulaConverter.packageJSON]?
            .values.first?.asString(omitOutputPort: false))
        XCTAssertTrue(reader.contains("StaticFile(path: 'input:/app/semel.config')"), reader)
        XCTAssertTrue(reader.contains("StaticFile(path: 'input:/app/semel.machine.config')"), reader)
        XCTAssertFalse(reader.contains("Dependencies/X/semel."), reader)
    }
}
