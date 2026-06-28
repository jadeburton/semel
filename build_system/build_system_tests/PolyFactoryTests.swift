//
//  PolyFactoryTests.swift
//  build_system_tests
//

import XCTest

final class PolyFactoryTests: XCTestCase {

    // MARK: - JSON helpers (generic Encodable/Decodable extensions)

    func test_toJSON_fromJSON_roundTrip() throws {
        struct Point: Codable, Equatable { let x: Int; let y: Int }
        let original = Point(x: 3, y: 7)
        let decoded = try Point.fromJSON(try original.toJSON())
        XCTAssertEqual(decoded, original)
    }

    func test_toJSON_outputIsSortedKeys() throws {
        struct TwoKeys: Codable { let z: Int; let a: Int }
        let json = try TwoKeys(z: 1, a: 2).toJSON()
        let aIdx = json.range(of: "\"a\"")!.lowerBound
        let zIdx = json.range(of: "\"z\"")!.lowerBound
        XCTAssertLessThan(aIdx, zIdx, "keys should be sorted: 'a' must appear before 'z'")
    }

    func test_toJSON_outputIsValidJSON() throws {
        struct Simple: Codable { let value: String }
        let json = try Simple(value: "hello").toJSON()
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(json.utf8)))
    }

    // MARK: - PolySerializable.toJSON / PolyFactory.decode round-trips

    func test_configuration_toJSON_containsKind() throws {
        let config = Configuration(properties: ["tool": "compiler"])
        let json = try config.toJSON()
        XCTAssertTrue(json.contains("\"kind\""), "JSON must contain 'kind' discriminator")
    }

    func test_configuration_roundTrip() throws {
        let config = Configuration(properties: ["tool": "linker"])
        let json = try config.toJSON()
        let decoded = try PolyFactory.decodeAndCast(encodedJSON: json) as Configuration
        XCTAssertEqual(decoded.properties["tool"], "linker")
    }

    func test_staticFile_roundTrip() throws {
        let sf = StaticFile(properties: ["path": "src/hello.c"])
        let json = try sf.toJSON()
        let decoded = try PolyFactory.decodeAndCast(encodedJSON: json) as StaticFile
        XCTAssertEqual(decoded.containingPath, "src")
        XCTAssertEqual(decoded.name, "hello.c")
    }

    func test_staticFile_rootPath_roundTrip() throws {
        let sf = StaticFile(properties: ["path": "hello.c"])
        let json = try sf.toJSON()
        let decoded = try PolyFactory.decodeAndCast(encodedJSON: json) as StaticFile
        XCTAssertEqual(decoded.name, "hello.c")
        XCTAssertEqual(decoded.containingPath, "")
    }

    func test_folder_roundTrip() throws {
        let folder = Folder(properties: ["path" : ""])
        let json = try folder.toJSON()
        _ = try PolyFactory.decodeAndCast(encodedJSON: json) as Folder
    }

    // MARK: - PolyFactory.kind(forTypeName:)

    func test_kindForTypeName_configuration() throws {
        XCTAssertEqual(try PolyFactory.kind(forTypeName: "Configuration"), Configuration.kind)
    }

    func test_kindForTypeName_staticFile() throws {
        XCTAssertEqual(try PolyFactory.kind(forTypeName: "StaticFile"), StaticFile.kind)
    }

    func test_kindForTypeName_clangCompilerTool() throws {
        XCTAssertEqual(try PolyFactory.kind(forTypeName: "ClangCompilerTool"), ClangCompilerTool.kind)
    }

    func test_kindForTypeName_unknownType_throws() {
        XCTAssertThrowsError(try PolyFactory.kind(forTypeName: "NoSuchType")) { error in
            if case PolyFactoryError.unknownTypeName(let name) = error {
                XCTAssertEqual(name, "NoSuchType")
            } else {
                XCTFail("Expected PolyFactoryError.unknownTypeName")
            }
        }
    }

    // MARK: - Multiple kinds are distinct

    func test_allRegisteredKindsAreDistinct() throws {
        let kinds: [UInt] = [
            ProjectFinder.kind, ProjectBuilder.kind, StaticFile.kind, Folder.kind,
            ClangLinkerTool.kind, ClangCompilerTool.kind, ClangPreprocessorTool.kind,
            ClangLinkerToolConfiguration.kind, ClangCompilerToolConfiguration.kind,
            ClangPreprocessorToolConfiguration.kind, Configuration.kind, IncludeFinder.kind
        ]
        XCTAssertEqual(kinds.count, Set(kinds).count, "Each NodeFunction must have a unique kind")
    }
}
