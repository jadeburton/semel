// CacheEvictionTests.swift
// SemelCacheTests
//
// B-148's order and trim with no database: the policy over sizes as rows give them, and the
// trim over a store held in memory. A store that answers the protocol's questions is all a
// trim needs, which is what lets a cache server trim with the engine's rule.

import Foundation
import SemelCache
import SemelNodeKit
import XCTest

final class CacheEvictionTests: XCTestCase {

    // MARK: - The policy on its own

    func test_thePolicyLeavesOutHeldEntriesAndOrdersTheRest() {
        func size(_ name: String, cost: Int, bytes: Int, lastUse: Int = 1, held: Bool = false) -> CacheEntrySize {
            CacheEntrySize(hash: name, nodeType: "SampleTool", cost: cost, lastUse: lastUse, bytes: bytes, sharedBytes: 0,
                           heldByNode: held)
        }
        let sizes = [size("held", cost: 0, bytes: 100, held: true),
                     size("empty", cost: 0, bytes: 0),
                     size("recent", cost: 0, bytes: 100, lastUse: 2),
                     size("dear", cost: 900, bytes: 100),
                     size("cheap", cost: 1, bytes: 100),
                     size("cheapToo", cost: 1, bytes: 100)]

        let order = CacheEvictionPolicy.order(sizes, lastUsingSettle: 2).map(\.hash)

        XCTAssertEqual(order, ["cheap", "cheapToo", "dear", "empty", "recent"])
    }

    // MARK: - The trim over a store

    func test_aTrimEvictsTheCheapestBuildsPerByteUntilUnderTheLimit() throws {
        let store = MemoryCacheStore()
        try store.save(hash: "dear", nodeType: "SwiftCompiler", cost: 9_000, content: Data(),
                       objects: [CachedObject(hash: "module", bytes: 100)])
        try store.save(hash: "cheap", nodeType: "SwiftLinker", cost: 10, content: Data(),
                       objects: [CachedObject(hash: "binary", bytes: 100)])
        try store.save(hash: "cheapToo", nodeType: "SwiftLinker", cost: 20, content: Data(),
                       objects: [CachedObject(hash: "library", bytes: 100)])

        let trim = try store.trim(toLimit: ByteCount(bytes: 150))

        XCTAssertEqual(trim.evictions.map(\.entry.hash), ["cheap", "cheapToo"])
        XCTAssertEqual(trim.bytesBefore, ByteCount(bytes: 300))
        XCTAssertEqual(trim.bytesAfter, ByteCount(bytes: 100))
        XCTAssertEqual(trim.freed, ByteCount(bytes: 200))
        XCTAssertEqual(trim.evictedByType.map(\.nodeType), ["SwiftLinker"])
        XCTAssertEqual(try store.sizes().map(\.hash), ["dear"])
    }

    func test_aTrimUnderTheLimitEvictsNothing() throws {
        let store = MemoryCacheStore()
        try store.save(hash: "only", nodeType: "SampleTool", cost: 1, content: Data(),
                       objects: [CachedObject(hash: "object", bytes: 10)])

        let trim = try store.trim(toLimit: ByteCount(bytes: 10))

        XCTAssertEqual(trim.evictions, [])
        XCTAssertEqual(try store.sizes().map(\.hash), ["only"])
    }

    /// Two entries holding one object weigh half of it each: evicting the first gives back
    /// nothing, and the second, now its only holder, gives back the object.
    func test_twoEntriesSharingAnObjectAreEvictedTogether() throws {
        let store = MemoryCacheStore()
        try store.save(hash: "first", nodeType: "SampleTool", cost: 1, content: Data(),
                       objects: [CachedObject(hash: "shared", bytes: 100)])
        try store.save(hash: "second", nodeType: "SampleTool", cost: 2, content: Data(),
                       objects: [CachedObject(hash: "shared", bytes: 100)])

        let trim = try store.trim(toLimit: ByteCount(bytes: 0))

        XCTAssertEqual(trim.evictions.map(\.entry.hash), ["first", "second"])
        XCTAssertEqual(trim.evictions.map(\.freed), [ByteCount(bytes: 0), ByteCount(bytes: 100)])
        XCTAssertEqual(trim.bytesAfter, ByteCount(bytes: 0))
    }

    // MARK: - Get and put

    func test_anEntryPutIsGotBackUnderTheKeyItsMaterialTakes() throws {
        let store    = MemoryCacheStore()
        let material = CacheKeyMaterial(nodeType: "SampleTool", implementationVersion: 1, properties: [],
                                        fingerprint: nil,
                                        inputs: [CacheKeyEntry(port: "input", wire: "a.c", value: .value("61"))])
        let entry = ProcessCacheEntry(outputValues: ["output": .value("6f")],
                                      specTable: GraphSpecTable(inputWireSpecs: [:], rows: [:]),
                                      keyMaterial: material)

        try store.put(entry, cost: 5, objects: [CachedObject(hash: "6f", bytes: 1)])

        let key = try material.cacheKey()
        XCTAssertEqual(try store.entry(forKey: key)?.encoded(), try entry.encoded())
        XCTAssertEqual(try store.sizes().first?.nodeType, "SampleTool")
        XCTAssertEqual(try store.sizes().first?.cost, 5)
        XCTAssertEqual(try store.objects(ofEntry: key), ["6f"])
    }

    func test_bytesThatAreNotAnEntryAreAMiss() throws {
        let store = MemoryCacheStore()
        try store.save(hash: "damaged", nodeType: "SampleTool", cost: 1, content: Data("{}".utf8), objects: [])

        XCTAssertNil(try store.entry(forKey: "damaged"))
        XCTAssertNil(try store.entry(forKey: "absent"))
    }
}

// MARK: - A store in memory

/// The protocol answered from dictionaries, by the rules the engine's SQLite store keeps:
/// an object counted once however many entries hold it, an entry's size what it alone
/// holds, its share of the rest divided among the holders.
private final class MemoryCacheStore: CacheStore {

    private struct Row {
        let nodeType: String
        let cost:     Int
        var lastUse:  Int
        let content:  Data
        let objects:  [CachedObject]
    }

    private var rows: [String: Row] = [:]
    private var settle = 1
    private var lastUsingSettle = 0

    func content(hash: String) throws -> Data? {
        rows[hash]?.content
    }

    func save(hash: String, nodeType: String, cost: Int, content: Data, objects: [CachedObject]) throws {
        rows[hash] = Row(nodeType: nodeType, cost: cost, lastUse: settle, content: content,
                         objects: Set(objects).sorted { $0.hash < $1.hash })
    }

    func noteUse(hash: String) throws {
        rows[hash]?.lastUse = settle
    }

    func delete(hash: String) throws -> Bool {
        rows.removeValue(forKey: hash) != nil
    }

    func account() throws -> CacheAccount {
        let objects = Set(rows.values.flatMap(\.objects))
        return CacheAccount(bytes: objects.reduce(0) { $0 + $1.bytes }, settle: settle, lastUsingSettle: lastUsingSettle)
    }

    func sizes() throws -> [CacheEntrySize] {
        var holders: [String: Int] = [:]
        for row in rows.values {
            for object in row.objects {
                holders[object.hash, default: 0] += 1
            }
        }
        return rows.keys.sorted().compactMap { hash in
            guard let row = rows[hash] else {
                return nil
            }
            let alone  = row.objects.filter { holders[$0.hash] == 1 }.reduce(0) { $0 + $1.bytes }
            let shared = row.objects.compactMap { object -> Int? in
                guard let count = holders[object.hash], count > 1 else {
                    return nil
                }
                return (object.bytes + count - 1) / count
            }.reduce(0, +)
            return CacheEntrySize(hash: hash, nodeType: row.nodeType, cost: row.cost, lastUse: row.lastUse,
                                  bytes: alone, sharedBytes: shared, heldByNode: false)
        }
    }

    func objects(ofEntry hash: String) throws -> [String] {
        rows[hash]?.objects.map(\.hash) ?? []
    }
}
