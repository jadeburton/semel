//
//  ModuleMapWriterTests.swift
//  SemelSwiftTests
//
//  The module map SwiftPM writes for a C target whose public headers have none (B-55):
//  what `import CrashReporter` and `import Minizip` load.
//

@testable import SemelSwift
import XCTest
import SemelNodeKit
import SemelDatabaseModels

final class ModuleMapWriterTests: SemelSwiftTestCase {

    private func published(_ properties: [String: String]) throws -> String {
        let writer = try ModuleMapWriter(thisNode: NodeRecord(id: 1, kind: ModuleMapWriter.kind, name: nil,
                                                              properties: properties, scheduled: false, identity: nil))
        guard let output = try writer.didCreate() else {
            throw NodeError.processNotSupported
        }
        return try XCTUnwrap(output.outputValues[ModuleMapWriter.outputPort]).expectValue().resolveAsString()
    }

    /// SwiftPM's text, with the umbrella relative to the folder the map sits in, so the map
    /// is right wherever that folder is placed and names no sandbox.
    func test_anUmbrellaHeaderIsNamedRelativeToTheMapsFolder() throws {
        XCTAssertEqual(try published(["moduleName": "CrashReporter", "umbrellaHeader": "CrashReporter.h"]),
                       "module CrashReporter {\n    umbrella header \"CrashReporter.h\"\n    export *\n}\n")
    }

    func test_anUmbrellaDirectoryIsTheMapsOwnFolder() throws {
        XCTAssertEqual(try published(["moduleName": "Squeeze", "umbrellaDirectory": "."]),
                       "module Squeeze {\n    umbrella \".\"\n    export *\n}\n")
    }

    func test_aQuoteInAPathIsEscapedAsAModuleMapStringLiteralWantsIt() throws {
        XCTAssertTrue(try published(["moduleName": "Kit", "umbrellaHeader": "odd\"name.h"]).contains("\"odd\\\"name.h\""))
    }

    func test_bothUmbrellasOrNeitherIsAnErrorNamingTheTwo() throws {
        for properties in [["moduleName": "Kit"],
                           ["moduleName": "Kit", "umbrellaHeader": "Kit.h", "umbrellaDirectory": "."]] {
            XCTAssertThrowsError(try published(properties)) { error in
                XCTAssertEqual(error as? ErrorCondition,
                               .propertiesExclusive(type: "ModuleMapWriter", properties: ["umbrellaHeader", "umbrellaDirectory"]))
            }
        }
    }

    /// A source with nothing to wait for: its value is its properties, published when the
    /// node is made, so it declares no input port for anything to schedule it by.
    func test_itDeclaresNoInputPorts() {
        XCTAssertTrue(ModuleMapWriter.descriptor.inputPorts.isEmpty)
    }
}
