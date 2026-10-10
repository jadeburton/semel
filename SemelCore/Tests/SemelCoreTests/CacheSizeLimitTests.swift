//
//  CacheSizeLimitTests.swift
//  SemelCore
//
//  B-148. The cache is limited by size, not by count: an entry's size is the bytes of the
//  objects it alone holds, the running total counts every object once and leaves out what
//  the input file system holds, and a trim at the limit evicts in the policy's order —
//  never an entry a node of the graph stands on — and nothing beyond what it must.
//

@testable import SemelCore
import Foundation
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class CacheSizeLimitTests: SemelCoreTestCase {

    private var engine: BuildEngine!

    private var database: DatabaseLayer { engine.database }

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func key(_ name: String) -> String {
        Sha256.hash(Array(name.utf8))
    }

    /// An object as the account sees it, for the tests that weigh rows and not bytes: a
    /// hash nothing in the store has, of the size given.
    private func object(_ name: String, bytes: Int) -> CachedObject {
        CachedObject(hash: key("object " + name), bytes: bytes)
    }

    /// An entry under the key `name` names, holding `objects`, built at `cost`.
    @discardableResult
    private func entry(_ name: String, cost: Int = 1, holding objects: [CachedObject]) throws -> String {
        let hash = key(name)
        try database.cacheEntry.save(hash: hash, nodeType: "SampleTool", cost: cost, content: Data("{}".utf8), objects: objects)
        return hash
    }

    private var total: Int {
        get throws { try database.cacheEntry.account().bytes }
    }

    private func size(of hash: String) throws -> Int {
        try XCTUnwrap(database.cacheEntry.sizes().first { $0.hash == hash }).bytes
    }

    private func limit(_ bytes: Int) throws {
        try database.cacheEntry.setLimit(bytes: bytes)
    }

    private func remaining() throws -> Set<String> {
        Set(try database.cacheEntry.selectAllHashes())
    }

    /// A source file whose port holds `text`, as a push leaves it.
    @discardableResult
    private func pushed(_ text: String, at path: String) throws -> DataObjectHash {
        let hash = try text.intern()
        let (node, _) = try GraphSpecNode.parse("StaticFile(path: '\(path)')").findOrCreateMatchingNode()
        try node.writeToOutputPort(StaticFile.outputPort, value: .value(hash))
        return hash
    }

    /// Stores a build through the path a run takes: the node's outputs, sized from the
    /// store as the collector would follow them.
    @discardableResult
    private func cachedBuild(of node: SampleTool, configuration: String,
                             outputs: [String: NodeValue]) throws -> String {
        let input = ProcessInput(inputValues: [SampleTool.configuration: ["configuration": .value(try configuration.intern())],
                                               SampleTool.input: [:]])
        let material = try node.buildCacheKeyMaterial(input: input)
        try node.saveCacheForAllInputsAndOutputs(keyMaterial: material, processingDuration: 0.01,
                                                 output: AppliedOutput(outputValues: outputs,
                                                                       specTable: GraphSpecTable(inputWireSpecs: [:], rows: [:])))
        return try material.cacheKey()
    }

    private func sampleTool() throws -> SampleTool {
        let (node, _) = try GraphSpecNode(SampleTool.self).findOrCreateMatchingNode()
        return try SampleTool(thisNode: node)
    }

    // MARK: - What an entry costs

    /// One object two entries hold is one object on disk: the total counts it once, and
    /// neither entry's own size does, since evicting either alone gives it back to nobody.
    func test_anObjectTwoEntriesHoldIsCountedOnceAndInNeitherEntrysOwnSize() throws {
        let shared = object("shared", bytes: 1_000)
        let first  = try entry("first", holding: [shared, object("first's own", bytes: 10)])
        let second = try entry("second", holding: [shared, object("second's own", bytes: 20)])

        XCTAssertEqual(try total, 1_030)
        XCTAssertEqual(try size(of: first), 10)
        XCTAssertEqual(try size(of: second), 20)

        XCTAssertTrue(try database.cacheEntry.delete(hash: first))
        XCTAssertEqual(try total, 1_020, "the shared object stays, held by the other")
        XCTAssertEqual(try size(of: second), 1_020, "and is the other's alone now")
    }

    /// A build whose output is a file the push already holds — a copy — adds nothing to the
    /// cache: the bytes are the input file system's, and evicting the entry would give
    /// none of them back.
    func test_anEntryWhoseObjectsTheInputFileSystemHoldsCostsNothing() throws {
        let source = try pushed("the bytes of a pushed source, which a copying node passes on", at: "input:/a.txt")
        let copied = try cachedBuild(of: try sampleTool(), configuration: "copy=1", outputs: [SampleTool.output: .value(source)])

        try database.cacheEntry.refreshInputHolding(inputKinds: BuildEngine.inputFileSystemKinds)

        XCTAssertEqual(try total, 0)
        XCTAssertEqual(try size(of: copied), 0)
        XCTAssertEqual(try engine.recountedCacheBytes(), ByteCount(bytes: 0))
    }

    /// And the other way: once the source no longer holds it, the cache does.
    func test_anObjectThePushLetsGoIsCountedByTheCacheThatStillHoldsIt() throws {
        let source = try pushed("first content of the source", at: "input:/a.txt")
        try cachedBuild(of: try sampleTool(), configuration: "copy=1", outputs: [SampleTool.output: .value(source)])
        try database.cacheEntry.refreshInputHolding(inputKinds: BuildEngine.inputFileSystemKinds)
        XCTAssertEqual(try total, 0)

        try pushed("the source edited", at: "input:/a.txt")
        try database.cacheEntry.refreshInputHolding(inputKinds: BuildEngine.inputFileSystemKinds)

        let expected = try XCTUnwrap(DataObjectStore.shared.size(hash: source))
        XCTAssertEqual(try total, expected)
        XCTAssertEqual(try engine.recountedCacheBytes(), ByteCount(bytes: expected))
    }

    /// The collector's reading of what an entry refers to is the accounting's: a tree
    /// manifest's files are held by the entry that holds the manifest.
    func test_theFilesOfATreeAnEntryHoldsAreCountedWithIt() throws {
        let file     = try "a file inside a tree, named only by the manifest".intern()
        let manifest = try TreeManifest(entries: [TreeManifestEntry(path: "lib/a.o", hash: file, mode: 0o644)]).toJSON().intern()

        let held = BuildEngine.heldObjects(outputValues: [SampleTool.output: .value(manifest)], in: DataObjectStore.shared)

        XCTAssertEqual(Set(held.map(\.hash)), [manifest, file])
        XCTAssertEqual(held.first { $0.hash == file }?.bytes, DataObjectStore.shared.size(hash: file))
    }

    /// The running total is kept by every save and delete; a recount from the entries
    /// themselves, through the store, is what it must equal.
    func test_theRunningTotalMatchesARecount() throws {
        let tool   = try sampleTool()
        let shared = try "an object two builds produce alike".intern()
        let source = try pushed("a source a third build copies", at: "input:/b.txt")
        let first  = try cachedBuild(of: tool, configuration: "x=1",
                                     outputs: [SampleTool.output: .value(try "first output".intern()),
                                               SampleTool.errorLog: .value(shared)])
        try cachedBuild(of: tool, configuration: "x=2",
                        outputs: [SampleTool.output: .value(try "second output, rather longer than the first".intern()),
                                  SampleTool.errorLog: .value(shared)])
        try cachedBuild(of: tool, configuration: "x=3", outputs: [SampleTool.output: .value(source)])
        // The first key built again, to another output: its old objects leave with it.
        try cachedBuild(of: tool, configuration: "x=1",
                        outputs: [SampleTool.output: .value(try "first output, built again".intern()),
                                  SampleTool.errorLog: .noValue(reason: .error(documentHash: try "a message".intern()))])
        try database.cacheEntry.refreshInputHolding(inputKinds: BuildEngine.inputFileSystemKinds)
        XCTAssertEqual(try total, try engine.recountedCacheBytes().bytes)
        XCTAssertEqual(try total, try database.cacheEntry.bytesByObjectRows())

        XCTAssertTrue(try database.cacheEntry.delete(hash: first))
        XCTAssertEqual(try total, try engine.recountedCacheBytes().bytes)
        XCTAssertGreaterThan(try total, 0)

        _ = try database.cacheEntry.deleteAll()
        XCTAssertEqual(try total, 0)
        XCTAssertEqual(try engine.recountedCacheBytes(), ByteCount(bytes: 0))
    }

    // MARK: - What a trim evicts

    func test_aCacheAtItsLimitIsNotTrimmed() throws {
        try entry("one", holding: [object("one", bytes: 100)])
        try entry("two", holding: [object("two", bytes: 100)])
        try limit(200)

        let trim = try engine.trimCache()

        XCTAssertEqual(trim.evictions, [])
        XCTAssertEqual(try remaining().count, 2)
    }

    /// Three entries of one size; the one that took least to build per byte goes, and the
    /// trim stops as soon as the total is under the limit.
    func test_theLowestCostPerByteGoesFirstAndNothingMore() throws {
        let middling  = try entry("middling", cost: 100, holding: [object("middling", bytes: 100)])
        let cheapest  = try entry("cheapest", cost: 10, holding: [object("cheapest", bytes: 100)])
        let dearest   = try entry("dearest", cost: 1_000, holding: [object("dearest", bytes: 100)])
        try limit(250)

        let trim = try engine.trimCache()

        XCTAssertEqual(trim.evictions.map(\.entry.hash), [cheapest])
        XCTAssertEqual(trim.freed, ByteCount(bytes: 100))
        XCTAssertEqual(try remaining(), [middling, dearest])
        XCTAssertEqual(try total, 200)
    }

    /// Cost per byte, not cost: a large entry that was quick to build goes before a small
    /// one that was slow, though its cost alone is the larger.
    func test_aLargeQuickBuildGoesBeforeASmallSlowOne() throws {
        let largeQuick = try entry("large and quick", cost: 50, holding: [object("large", bytes: 1_000)])
        let smallSlow  = try entry("small and slow", cost: 40, holding: [object("small", bytes: 10)])
        try limit(500)

        let trim = try engine.trimCache()

        XCTAssertEqual(trim.evictions.map(\.entry.hash), [largeQuick])
        XCTAssertEqual(try remaining(), [smallSlow])
    }

    /// What the last settle wrote or read goes after everything it did not, however cheap.
    func test_anEntryTheLastSettleUsedGoesAfterEveryOtherEntry() throws {
        let older = try entry("older", cost: 100, holding: [object("older", bytes: 100)])
        let other = try entry("other", cost: 200, holding: [object("other", bytes: 100)])
        try database.cacheEntry.closeSettle()
        let recent = try entry("recent", cost: 1, holding: [object("recent", bytes: 100)])
        try database.cacheEntry.closeSettle()
        try limit(150)

        let trim = try engine.trimCache()

        XCTAssertEqual(trim.evictions.map(\.entry.hash), [older, other])
        XCTAssertEqual(try remaining(), [recent])
    }

    /// An entry a node records as the build its outputs are is never evicted, even when
    /// it is the cheapest and the cache stays over its limit without it.
    func test_anEntryANodeStandsOnIsNeverEvicted() throws {
        let held = try entry("held", cost: 1, holding: [object("held", bytes: 1_000)])
        let free = try entry("free", cost: 1_000, holding: [object("free", bytes: 10)])
        let node = try sampleTool()
        try database.cacheEntry.recordKey(held, forNodeID: try node.thisNode.requireID())
        try limit(0)

        let trim = try engine.trimCache()

        XCTAssertEqual(trim.evictions.map(\.entry.hash), [free])
        XCTAssertEqual(try remaining(), [held])
        XCTAssertEqual(trim.bytesAfter, ByteCount(bytes: 1_000))
        XCTAssertTrue(BuildEngine.describe(trim).contains("held by entries the graph's nodes hold values from"))
    }

    /// The record moves with the node: once it writes another build, the first is free.
    func test_aNodeThatMovesOnLeavesItsOldEntryEvictable() throws {
        let old    = try entry("old", holding: [object("old", bytes: 100)])
        let newer  = try entry("newer", holding: [object("newer", bytes: 100)])
        let nodeID = try sampleTool().thisNode.requireID()
        try database.cacheEntry.recordKey(old, forNodeID: nodeID)
        try database.cacheEntry.recordKey(newer, forNodeID: nodeID)
        try limit(100)

        XCTAssertEqual(try engine.trimCache().evictions.map(\.entry.hash), [old])
    }

    /// Two entries sharing their one object each hold nothing alone, and each weighs half
    /// of it: the first to go gives back nothing, the second the whole object.
    func test_entriesThatShareAnObjectEachWeighTheirShareAndGoTogether() throws {
        let shared = object("shared", bytes: 500)
        let first  = try entry("first", cost: 1, holding: [shared])
        let second = try entry("second", cost: 1, holding: [shared])
        let own    = try entry("own", cost: 1_000, holding: [object("own", bytes: 10)])
        XCTAssertEqual(try database.cacheEntry.sizes().first { $0.hash == first }?.sharedBytes, 250)
        try limit(10)

        let trim = try engine.trimCache()

        XCTAssertEqual(trim.evictions.map(\.entry.hash), [first, second].sorted())
        XCTAssertEqual(trim.evictions.map(\.freed), [ByteCount(bytes: 0), ByteCount(bytes: 500)])
        XCTAssertEqual(try remaining(), [own])
        XCTAssertEqual(try total, 10)
    }

    /// What an entry shares with one a node stands on is not its to give back.
    func test_anObjectSharedWithAnEntryANodeStandsOnWeighsNothing() throws {
        let shared  = object("shared", bytes: 500)
        let held    = try entry("held", holding: [shared])
        let sharing = try entry("sharing", holding: [shared])
        try database.cacheEntry.recordKey(held, forNodeID: try sampleTool().thisNode.requireID())
        try limit(0)

        XCTAssertEqual(try database.cacheEntry.sizes().first { $0.hash == sharing }?.weight, 0)
        XCTAssertEqual(try engine.trimCache().evictions, [])
        XCTAssertEqual(try remaining(), [held, sharing])
    }

    /// An entry that costs nothing gives nothing back, so no limit evicts it.
    func test_anEntryThatCostsNothingIsNotEvicted() throws {
        let source = try pushed("a pushed file a build passed on unchanged", at: "input:/c.txt")
        let copied = try cachedBuild(of: try sampleTool(), configuration: "copy=1", outputs: [SampleTool.output: .value(source)])
        try database.cacheEntry.refreshInputHolding(inputKinds: BuildEngine.inputFileSystemKinds)
        try limit(0)

        XCTAssertEqual(try engine.trimCache().evictions, [])
        XCTAssertEqual(try remaining(), [copied])
    }

    // MARK: - The limit

    func test_theLimitIsTheDefaultUntilOneIsSetAndThenTheOneSet() throws {
        XCTAssertEqual(try engine.cacheLimit().limit, ByteCount.gibibytes(10))
        XCTAssertTrue(try engine.cacheLimit().isDefault)

        try engine.setCacheLimit(ByteCount(bytes: 3 * ByteCount.mebibyte))

        XCTAssertEqual(try engine.cacheLimit().limit, ByteCount(bytes: 3 * ByteCount.mebibyte))
        XCTAssertFalse(try engine.cacheLimit().isDefault)
        XCTAssertEqual(try database.cacheEntry.account().limitBytes, 3 * ByteCount.mebibyte, "stored in the graph")
    }

    /// Lowering the limit trims at once, and `cache` says what that trim evicted.
    func test_loweringTheLimitTrimsAtOnceAndTheReportSaysWhatWent() throws {
        let dear  = try entry("dear", cost: 1_000, holding: [object("dear", bytes: 100)])
        let cheap = try entry("cheap", cost: 1, holding: [object("cheap", bytes: 100)])

        let trim = try engine.setCacheLimit(ByteCount(bytes: 150))

        XCTAssertEqual(trim.evictions.map(\.entry.hash), [cheap])
        let report = try engine.cacheReport()
        XCTAssertEqual(report.entries.map(\.hash), [dear])
        XCTAssertEqual(report.bytes, ByteCount(bytes: 100))
        XCTAssertEqual(report.limit, ByteCount(bytes: 150))
        XCTAssertEqual(report.lastTrim?.evictions.map(\.entry.hash), [cheap])
    }

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
}

// MARK: - On a running loop

/// A graph that writes more than the limit keeps building, and the trim after its settle
/// says what it evicted. Five labelling tools read five sources; the limit holds three
/// builds. The first settle's five are what the graph stands on, so nothing goes; after
/// every source is edited the graph stands on five new ones, and the old five go.
final class CacheSizeLimitLoopTests: SemelCoreTestCase {

    private var engine: BuildEngine!
    private let notices = LineRecorder()

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
        engine.noticeReporter = { [notices] line in notices.record(line) }
        engine.startProcessingLoop()
        engine.waitUntilIdleBlocking()
    }

    override func tearDown() {
        engine.stopProcessingLoop()
        engine.waitUntilIdleBlocking()
        engine = nil
        super.tearDown()
    }

    private let sourceCount = 5
    private let sourceBytes = 1_000

    private func path(_ index: Int) -> String {
        "input:/src/\(index).txt"
    }

    private func push(edition: String) throws {
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders("src", pinned: true)
        for index in 0..<sourceCount {
            let (node, _) = try GraphSpecNode.parse("StaticFile(path: '\(path(index))')").findOrCreateMatchingNode()
            let file = try XCTUnwrap(node.nodeAsAny() as? StaticFile)
            let text = "\(edition) \(index) " + String(repeating: "x", count: sourceBytes)
            _ = try file.replaceContent(try text.intern())
        }
    }

    private func settle() async {
        engine.signalWorkAvailable()
        await engine.waitUntilIdle()
    }

    func test_aGraphThatWritesMoreThanTheLimitKeepsBuildingAndSaysWhatWasEvicted() async throws {
        try engine.setCacheLimit(ByteCount(bytes: 3 * 1_100))
        engine.beginBatch()
        var tools: [ObjectID] = []
        do {
            try push(edition: "first")
            for index in 0..<sourceCount {
                let spec = "LabellingSampleTool(input: ['source': StaticFile(path: '\(path(index))').output]).output"
                tools.append(try GraphSpecNode.parse(spec).findOrCreateMatchingNode().fromNode.requireID())
            }
        } catch {
            engine.endBatch()
            throw error
        }
        engine.endBatch()
        await settle()

        let firstKeys = Set(try engine.database.cacheEntry.selectAllHashes())
        XCTAssertEqual(firstKeys.count, sourceCount)
        XCTAssertEqual(notices.lines.filter { $0.contains("evicted") }, [], "every entry is one the graph stands on")
        XCTAssertGreaterThan(try engine.database.cacheEntry.account().bytes, 3 * 1_100)

        try push(edition: "second")
        await settle()

        for nodeID in tools {
            let port = try engine.database.outputPort.select(nodeID: nodeID, nameSymbolID: LabellingSampleTool.output.asSymbolID())
            XCTAssertEqual(port?.valueKind, .value, "the graph kept building")
            XCTAssertTrue(try port?.dataObjectHash?.resolveAsString().hasPrefix("labelled: second") ?? false)
        }
        let kept = Set(try engine.database.cacheEntry.selectAllHashes())
        XCTAssertTrue(kept.isDisjoint(with: firstKeys), "the first settle's entries were evicted")
        XCTAssertEqual(kept.count, sourceCount, "the second's are what the graph stands on")
        let line = try XCTUnwrap(notices.lines.first { $0.contains("evicted") })
        XCTAssertTrue(line.contains("evicted 5 entries"), line)
        XCTAssertTrue(line.contains("LabellingSampleTool 5"), line)
        XCTAssertEqual(try engine.cacheReport().lastTrim?.evictions.count, sourceCount)
        XCTAssertEqual(try engine.database.cacheEntry.account().bytes, try engine.recountedCacheBytes().bytes)
    }
}
