//
//  PolyFactoryTests.swift
//  build_system_tests
//

@testable import SemelCore
import XCTest
import SemelNodeKit

final class PolyFactoryTests: SemelCoreTestCase {

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

    // MARK: - Unknown kinds
    //
    // In-process an unknown kind is a programming error. Once this format is on a socket
    // it is routine — an older client, a newer server, a garbled or hostile frame. None of
    // those may take the process down.

    func test_decodingAnUnregisteredKindThrows() {
        let json = #"{"kind": 999999, "object": {}}"#

        XCTAssertThrowsError(try PolyFactory.decode(encodedJSON: json)) { error in
            guard case PolyFactoryError.unknownKind(let kind) = error else {
                return XCTFail("expected unknownKind, got \(error)")
            }
            XCTAssertEqual(kind, 999999)
        }
    }

    func test_lookingUpAnUnregisteredKindThrows() {
        XCTAssertThrowsError(try PolyFactory.type(kind: 999999))
        XCTAssertThrowsError(try PolyFactory.decodableType(kind: 999999))
    }

    // MARK: - Kind collisions
    //
    // `kind` is one flat number space shared by every polymorphic type. Registering a
    // duplicate used to overwrite silently, which surfaces later as a wrong-type decode
    // somewhere unrelated.

    private struct FirstClaimant: PolySerializable {
        static let kind: UInt = 987_001
        let value: String
    }

    private struct SecondClaimant: PolySerializable {
        static let kind: UInt = 987_001
        let value: String
    }

    func test_registeringADuplicateKindIsRejected() throws {
        try PolyFactory.register(types: [FirstClaimant.self])

        XCTAssertThrowsError(try PolyFactory.register(types: [SecondClaimant.self])) { error in
            guard case PolyFactoryError.duplicateKind(let kind, _, _) = error else {
                return XCTFail("expected duplicateKind, got \(error)")
            }
            XCTAssertEqual(kind, 987_001)
        }
    }

    func test_registeringTheSameTypeTwiceIsFine() throws {
        try PolyFactory.register(types: [FirstClaimant.self])
        XCTAssertNoThrow(try PolyFactory.register(types: [FirstClaimant.self]),
                         "re-registering an identical type is idempotent, not a collision")
    }

    // MARK: - Multiple kinds are distinct

    func test_allRegisteredKindsAreDistinct() throws {
        let kinds: [UInt] = [
            ProjectFinder.kind, ProjectBuilder.kind, StaticFile.kind, Folder.kind,
            OutputFile.kind, Configuration.kind, FolderManifest.kind
        ]
        XCTAssertEqual(kinds.count, Set(kinds).count, "Each Node must have a unique kind")
    }
}
