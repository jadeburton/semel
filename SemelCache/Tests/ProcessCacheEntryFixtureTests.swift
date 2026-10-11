// ProcessCacheEntryFixtureTests.swift
// SemelCacheTests
//
// The bytes of a stored entry, pinned. An engine and a cache server read and write the same
// entries, and an entry the engine wrote before this package existed is in someone's
// database: so the encoding, the material's text and the key are fixed here as the engine
// produced them, before the types moved out of `SemelCore`, and a change to any of them
// fails this file rather than turning every stored entry into a miss without a word.

import Foundation
import SemelCache
import SemelNodeKit
import XCTest

final class ProcessCacheEntryFixtureTests: XCTestCase {

    // MARK: - The fixture

    /// Every shape the encoding has: a property holding a quote and a newline, a
    /// fingerprint, inputs carrying a value, a removal and a failure, output values of each
    /// kind, and a spec table with a row whose wire reads no port.
    private func fixtureEntry() -> ProcessCacheEntry {
        let material = CacheKeyMaterial(
            nodeType: "SampleTool",
            implementationVersion: 3,
            properties: [CacheKeyProperty(key: "flags", value: "-O2 \"quoted\"\nsecond line"),
                         CacheKeyProperty(key: "path", value: "src/a/b.c")],
            fingerprint: "sdk 26.0 / 1f2e",
            inputs: [CacheKeyEntry(port: "configuration", wire: "configuration", value: .value(hex("a"))),
                     CacheKeyEntry(port: "input", wire: "src/a/b.c", value: .value(hex("b"))),
                     CacheKeyEntry(port: "input", wire: "src/a/gone.c", value: .noValue(reason: .deleted)),
                     CacheKeyEntry(port: "headers", wire: "include/x.h",
                                   value: .noValue(reason: .error(documentHash: hex("c"))))])
        let parent    = GraphSpecTable.Reference(identity: hex("e"), outputPort: nil)
        let reference = GraphSpecTable.Reference(identity: hex("d"), outputPort: "manifest")
        let row = GraphSpecTable.Row(typeName: "Folder",
                                     properties: [GraphSpecProperty(key: "path", value: "input:/include")],
                                     inputs: [GraphSpecTable.Port(portName: "parent",
                                                                  wires: [GraphSpecTable.Wire(name: "up", source: parent)])])
        let table = GraphSpecTable(inputWireSpecs: ["headers": ["include": reference]], rows: [hex("d"): row])
        return ProcessCacheEntry(outputValues: ["output":   .value(hex("f")),
                                                "errorLog": .value(""),
                                                "infoLog":  .noValue(reason: .pending)],
                                 specTable: table,
                                 keyMaterial: material)
    }

    private func hex(_ digit: String) -> String {
        String(repeating: digit, count: 64)
    }

    /// The entry's bytes as `SemelCore` stored them at 2c41b00, the commit before the move.
    private let pinnedEncoding =
        #"{"keyMaterial":{"fingerprint":"sdk 26.0 \/ 1f2e","implementationVersion":3,"inputs":["#
      + #"{"port":"configuration","value":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","wire":"configuration"},"#
      + #"{"port":"input","value":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","wire":"src\/a\/b.c"},"#
      + #"{"noValue":{"deleted":{}},"port":"input","wire":"src\/a\/gone.c"},"#
      + #"{"noValue":{"error":{"documentHash":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}},"#
      + #""port":"headers","wire":"include\/x.h"}],"#
      + #""nodeType":"SampleTool","properties":[{"key":"flags","value":"-O2 \"quoted\"\nsecond line"},"#
      + #"{"key":"path","value":"src\/a\/b.c"}]},"#
      + #""outputValues":{"errorLog":{"value":{"_0":""}},"infoLog":{"noValue":{"reason":{"pending":{}}}},"#
      + #""output":{"value":{"_0":"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"}}},"#
      + #""specTable":{"inputWireSpecs":{"headers":{"include":{"#
      + #""identity":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","outputPort":"manifest"}}},"#
      + #""rows":{"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd":{"inputs":[{"portName":"parent","#
      + #""wires":[{"name":"up","source":{"identity":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}}]}],"#
      + #""properties":[{"key":"path","value":"input:\/include"}],"typeName":"Folder"}}}}"#

    /// The material's text as `SemelCore` hashed it at the same commit.
    private let pinnedText = """
        node SampleTool@3
        property {"key":"flags","value":"-O2 \\"quoted\\"\\nsecond line"}
        property {"key":"path","value":"src/a/b.c"}
        fingerprint {"fingerprint":"sdk 26.0 / 1f2e"}
        input {"port":"configuration","value":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","wire":"configuration"}
        input {"port":"input","value":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","wire":"src/a/b.c"}
        input {"noValue":{"deleted":{}},"port":"input","wire":"src/a/gone.c"}
        input {"noValue":{"error":{"documentHash":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}},"port":"headers","wire":"include/x.h"}

        """

    /// The key `SemelCore` filed the entry under at the same commit.
    private let pinnedKey = "f6346181a7661c422766816417bf672b5b755bfee7f7272f2a43bf53b3fb47be"

    // MARK: - Tests

    func test_anEntryEncodesToThePinnedBytes() throws {
        XCTAssertEqual(String(decoding: try fixtureEntry().encoded(), as: UTF8.self), pinnedEncoding)
    }

    func test_theMaterialsTextIsThePinnedText() throws {
        XCTAssertEqual(try fixtureEntry().keyMaterial.canonicalText(), pinnedText)
    }

    func test_theKeyIsThePinnedKey() throws {
        XCTAssertEqual(try fixtureEntry().cacheKey(), pinnedKey)
    }

    /// An entry stored before the move reads back as the entry it was, and is written again
    /// as the same bytes.
    func test_thePinnedBytesDecodeAndEncodeAgainUnchanged() throws {
        let decoded = try ProcessCacheEntry.decoded(from: Data(pinnedEncoding.utf8))

        XCTAssertEqual(String(decoding: try decoded.encoded(), as: UTF8.self), pinnedEncoding)
        XCTAssertEqual(try decoded.cacheKey(), pinnedKey)
    }
}
