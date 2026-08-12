//
//  PolyFactoryTests.swift
//  build_system_tests
//

import BuildSystemCore
import XCTest

final class PolyFactoryTests: BuildSystemTestCase {

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
            Configuration.kind, IncludeFinder.kind
        ]
        XCTAssertEqual(kinds.count, Set(kinds).count, "Each NodeFunction must have a unique kind")
    }
}
