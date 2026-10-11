// CacheKeyTests.swift
// SemelCacheTests
//
// The key as a value: the same hex as the material hashes to, a bare string on the wire,
// and checked where a person types one.

import Foundation
import SemelCache
import SemelNodeKit
import XCTest

final class CacheKeyTests: XCTestCase {

    private func material() -> CacheKeyMaterial {
        CacheKeyMaterial(nodeType: "SampleTool", implementationVersion: 1,
                         properties: [CacheKeyProperty(key: "path", value: "src/a.c")],
                         fingerprint: nil,
                         inputs: [CacheKeyEntry(port: "input", wire: "src/a.c", value: .value(String(repeating: "a", count: 64)))])
    }

    func test_theTypedKeyIsTheHexTheMaterialHashesTo() throws {
        let material = material()

        XCTAssertEqual(try material.key().hash, try material.cacheKey())
        let entry = ProcessCacheEntry(outputValues: [:], specTable: GraphSpecTable(inputWireSpecs: [:], rows: [:]),
                                      keyMaterial: material)
        XCTAssertEqual(try entry.key(), try material.key())
    }

    /// On the wire a key is its hex and nothing else, so typing it moved no byte.
    func test_aKeyEncodesAsABareString() throws {
        let key = try material().key()

        let encoded = try JSONEncoder().encode([key])

        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "[\"\(key.hash)\"]")
        XCTAssertEqual(try JSONDecoder().decode([CacheKey].self, from: encoded), [key])
    }

    func test_aTypedKeyIsSixtyFourLowercaseHexDigits() throws {
        let hex = try material().cacheKey()

        XCTAssertEqual(CacheKey(parsing: hex), CacheKey(hash: hex))
        XCTAssertNil(CacheKey(parsing: "abc"), "too short")
        XCTAssertNil(CacheKey(parsing: hex.uppercased()), "the store files lowercase")
        XCTAssertNil(CacheKey(parsing: String(hex.dropLast()) + "g"), "not hex")
        XCTAssertNil(CacheKey(parsing: hex + "0"), "too long")
    }
}
