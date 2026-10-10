//
//  CacheDeclarationTests.swift
//  SemelCore
//
//  B-147. Whether a node's result is stored is declared by its type (`cachesOutputs`), and
//  nothing about a run decides it. Two tools read one pushed file on a real processing
//  loop: a `SampleTool`, which returns at once and caches by default, and an
//  `UncachedSampleTool`, which declares that it does not. The file is changed and changed
//  back; the first tool is answered from the cache, the second runs every time.
//

@testable import SemelCore
import SemelNodeKit
import XCTest

final class CacheDeclarationTests: SemelCoreTestCase {

    private var engine: BuildEngine!

    private let configPath = "input:/cfg/semel.config"

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
        engine.startProcessingLoop()
        engine.waitUntilIdleBlocking()
    }

    override func tearDown() {
        engine.stopProcessingLoop()
        engine.waitUntilIdleBlocking()
        engine = nil
        super.tearDown()
    }

    private func push(_ contents: String) throws {
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders("cfg", pinned: true)
        let (node, _) = try GraphSpecNode.parse("StaticFile(path: '\(configPath)')").findOrCreateMatchingNode()
        let file = try XCTUnwrap(node.nodeAsAny() as? StaticFile)
        _ = try file.replaceContent(try contents.intern())
    }

    private func nodeID(_ spec: String) throws -> ObjectID {
        try GraphSpecNode.parse(spec).findOrCreateMatchingNode().fromNode.requireID()
    }

    private func settle() async {
        engine.signalWorkAvailable()
        await engine.waitUntilIdle()
    }

    private var record: SettleRecord {
        get throws { try XCTUnwrap(engine.lastSettleRecord, "a settle that did work leaves a record") }
    }

    /// The node types the stored entries were written for, one per entry.
    private func storedNodeTypes() throws -> [String] {
        try engine.database.cacheEntry.selectAllContent().map {
            try ProcessCacheEntry.fromJSON(String(decoding: $0, as: UTF8.self)).keyMaterial.nodeType
        }.sorted()
    }

    /// One batch, one settle: both tools built over the file as it is first pushed.
    private func buildGraph() async throws -> (cached: ObjectID, uncached: ObjectID) {
        let fileSpec = "StaticFile(path: '\(configPath)').output"
        engine.beginBatch()
        let graph: (cached: ObjectID, uncached: ObjectID)
        do {
            try push("x=1\n")
            graph = (cached:   try nodeID("SampleTool(configuration: ['cfg': \(fileSpec)]).output"),
                     uncached: try nodeID("UncachedSampleTool(configuration: ['cfg': \(fileSpec)]).output"))
        } catch {
            engine.endBatch()
            throw error
        }
        engine.endBatch()
        await settle()
        return graph
    }

    /// How long a run took decides nothing: `SampleTool` returns at once, and its first
    /// result is what answers the file changed back.
    func test_aToolThatReturnsAtOnceIsAnsweredFromTheCacheOnItsSecondRun() async throws {
        let graph = try await buildGraph()
        XCTAssertEqual(try record.outcomes[graph.cached], .computed)

        try push("x=2\n")
        await settle()
        XCTAssertEqual(try record.outcomes[graph.cached], .computed, "a new key")

        try push("x=1\n")
        await settle()
        XCTAssertEqual(try record.outcomes[graph.cached], .fromCache, "the key of the first run")
    }

    /// The type that declares it does not cache runs on every settle that wakes it, the
    /// file changed back included, and leaves no entry behind.
    func test_aTypeDeclaredNotToCacheIsAlwaysComputedAndWritesNoEntry() async throws {
        let graph = try await buildGraph()
        try push("x=2\n")
        await settle()
        try push("x=1\n")
        await settle()

        XCTAssertEqual(try record.outcomes[graph.uncached], .computed)
        XCTAssertEqual(try storedNodeTypes(), ["SampleTool", "SampleTool"],
                       "one entry per key the caching tool ran under, none for the other")
    }
}
