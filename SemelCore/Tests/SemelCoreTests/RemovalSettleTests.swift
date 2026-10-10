//
//  RemovalSettleTests.swift
//  SemelCoreTests
//
//  B-149. A removal deletes what is removed, gives every consumer below it the state its
//  inputs stand in without running anything, deletes the nodes nothing holds any more, and
//  settles once. No tool is started against a removed source, and no cache entry is written
//  for a run over one.
//
//  A real processing loop over a formula found by the `ProjectFinder`, because what a
//  removal used to cost came from the loop: the finder waited for the builders it holds,
//  so a removed project's builder was let go of only once everything below it had run over
//  the removed sources, and the collector took the nodes at idle after that. One job at a
//  time, so that the recording runner is never asked from two threads.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class RemovalSettleTests: SemelCoreTestCase {

    private var engine: BuildEngine!
    private var database: DatabaseLayer { engine.database }
    private let reports = Reports()

    /// What the loop said, captured on its task and read on the test's.
    private final class Reports {
        private let lock = NSLock()
        private var errorBatches: [[ErrorReport.Entry]] = []
        private var summaries: [SettleSummary] = []

        func append(errors entries: [ErrorReport.Entry]) {
            lock.withLock { errorBatches.append(entries) }
        }

        func append(summary: SettleSummary) {
            lock.withLock { summaries.append(summary) }
        }

        var lastErrors: [ErrorReport.Entry]? {
            lock.withLock { errorBatches.last }
        }

        var settleCount: Int {
            lock.withLock { summaries.count }
        }

        var lastSummary: SettleSummary? {
            lock.withLock { summaries.last }
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false, jobs: 1)
        BuildEngine.shared = engine
        engine.errorReporter  = { [reports] entries in reports.append(errors: entries) }
        engine.settleReporter = { [reports] summary in reports.append(summary: summary) }
        engine.startProcessingLoop()
        engine.waitUntilIdleBlocking()
    }

    override func tearDown() {
        // A loop left running would keep processing against the next test's globals.
        engine.stopProcessingLoop()
        engine.waitUntilIdleBlocking()
        engine = nil
        CompilingSampleTool.runner = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private static let formula = """
        product 'out.txt' = CompilingSampleTool(input: ['a': StaticFile(path: <a.txt>).output,
                                                        'b': StaticFile(path: <b.txt>).output]).output
        """

    /// Pushes every file in one batch, as `push` of a folder does, and waits for the settle.
    private func push(_ files: [String: String]) throws {
        engine.beginBatch()
        defer {
            engine.endBatch()
            engine.waitUntilIdleBlocking()
        }
        for (relativePath, contents) in files.sorted(by: { $0.key < $1.key }) {
            _ = try StaticFile.push(Array(contents.utf8), mode: FileMetadata.defaultMode, at: Path(relativePath))
        }
    }

    /// The project: a formula compiling two sources into one product, built and settled.
    /// Returns the runner that built it.
    @discardableResult
    private func buildProject() throws -> RecordingToolRunner {
        let builder = RecordingToolRunner()
        CompilingSampleTool.runner = builder
        try push(["proj/semel.fmla": Self.formula, "proj/a.txt": "a", "proj/b.txt": "b"])
        XCTAssertEqual(builder.invocations.count, 1, "the project builds")
        XCTAssertEqual(try toolNodes().count, 1)
        return builder
    }

    /// Removes the path from the input file system in one batch, as `rm` does, and waits
    /// for the settle it causes.
    ///
    /// Returns how many passes the removal asked for, and how many it sent before its batch
    /// ended: every file it takes asks, and none of them is sent on its own.
    @discardableResult
    private func remove(_ relativePath: String) throws -> (requested: Int, sentInsideTheBatch: Int) {
        let requestedBefore = engine.wakeUpsRequested
        let sentBefore      = engine.loopSignalsSent
        engine.beginBatch()
        defer {
            engine.endBatch()
            engine.waitUntilIdleBlocking()
        }
        let node      = try XCTUnwrap(try engine.inputFileSystem.childNode(path: Path(relativePath)))
        let deletable = try XCTUnwrap(try node.nodeAsAny() as? UserDeletable)
        try deletable.deleteInInputFileSystem()
        return (engine.wakeUpsRequested - requestedBefore, engine.loopSignalsSent - sentBefore)
    }

    private func toolNodes() throws -> [NodeRecord] {
        try database.node.select(kind: CompilingSampleTool.kind)
    }

    private func valueKind(of nodeRecord: NodeRecord, port: String) throws -> OutputPort.ValueKind? {
        try database.outputPort.select(nodeID: try nodeRecord.requireID(), nameSymbolID: port.asSymbolID())?.valueKind
    }

    private func cacheKeys() throws -> Set<String> {
        Set(try database.cacheEntry.selectAll().map(\.hash))
    }

    // MARK: - A source removed from a project that stays

    /// The formula still names the removed file, so the compile stays in the graph and is
    /// woken by the removal. Its input is a value it cannot have: it publishes the state
    /// that stops a consumer, and the tool behind it is never started.
    func test_removingASourceStopsEveryConsumerWithoutRunningItsTool() throws {
        try buildProject()
        let afterRemoval = RecordingToolRunner()
        CompilingSampleTool.runner = afterRemoval

        try remove("proj/a.txt")

        XCTAssertEqual(afterRemoval.invocations.count, 0, "no tool is started against a removed source")
        let tool = try XCTUnwrap(try toolNodes().first)
        XCTAssertEqual(try valueKind(of: tool, port: CompilingSampleTool.output), .inputInError)
        let product = try XCTUnwrap(try database.node.select(kind: OutputFile.kind).first)
        XCTAssertEqual(try valueKind(of: product, port: OutputFile.statusOutputPort), .inputInError)
        let record = try XCTUnwrap(engine.lastSettleRecord)
        XCTAssertNil(record.outcomes[try tool.requireID()], "stopped, neither run nor answered from the cache")
        XCTAssertNil(record.outcomes[try product.requireID()])
    }

    /// What the report says is the removal, by the path, and nothing a tool said.
    func test_theReportAfterARemovalNamesTheRemovedSourceAndNoToolError() throws {
        try buildProject()
        CompilingSampleTool.runner = RecordingToolRunner()

        try remove("proj/a.txt")

        let entries = try XCTUnwrap(reports.lastErrors)
        XCTAssertEqual(entries.flatMap { $0.items.map(\.document) },
                       [.engine(.removed(path: "input:/proj/a.txt", isFolder: false), subject: nil)])
        XCTAssertEqual(entries.first?.downstreamCarrierCount, 2, "the compile and the product, folded onto it")
    }

    /// The builder reads the folder's listing, which the removal changed, and runs again
    /// over values; nothing is stored for a node whose input is the removed source.
    func test_noCacheEntryIsWrittenForARunOverTheRemovedSource() throws {
        try buildProject()
        let before = try cacheKeys()
        CompilingSampleTool.runner = RecordingToolRunner()

        try remove("proj/a.txt")

        let written = try database.cacheEntry.selectAll().filter { !before.contains($0.hash) }
        XCTAssertFalse(written.contains { $0.nodeType == "\(CompilingSampleTool.self)" })
        for entry in written {
            let decoded = try JSONDecoder().decode(ProcessCacheEntry.self, from: entry.content)
            let overARemovedSource = decoded.keyMaterial.inputs.contains { input in
                if case .noValue(.deleted) = input.value {
                    return true
                }
                return false
            }
            XCTAssertFalse(overARemovedSource, "\(entry.nodeType) stored a run over the removed source")
        }
    }

    /// Pushed back, the source is the input it was, and the compile is answered from the
    /// entry its first build wrote.
    func test_aSourcePushedBackIsAnsweredFromTheCache() throws {
        try buildProject()
        let afterRemoval = RecordingToolRunner()
        CompilingSampleTool.runner = afterRemoval

        try remove("proj/a.txt")
        try push(["proj/a.txt": "a"])

        XCTAssertEqual(afterRemoval.invocations.count, 0)
        let tool = try XCTUnwrap(try toolNodes().first)
        XCTAssertEqual(try valueKind(of: tool, port: CompilingSampleTool.output), .value)
    }

    // MARK: - A project removed

    /// The whole folder in one batch: one wake-up, one settle, in which the finder lets go
    /// of the project's builder and the collector takes everything only it held before any
    /// of it runs. What is left is the graph's roots and the finder.
    func test_removingAProjectFolderIsOneBatchOneSettleAndLeavesNothingHeldByIt() throws {
        try buildProject()
        let entriesBefore = try cacheKeys()
        let afterRemoval  = RecordingToolRunner()
        CompilingSampleTool.runner = afterRemoval
        let settlesBefore = reports.settleCount

        let signals = try remove("proj")

        XCTAssertGreaterThan(signals.requested, 1, "each file taken asks for a pass")
        XCTAssertEqual(signals.sentInsideTheBatch, 0, "none is sent before the batch ends")
        XCTAssertEqual(reports.settleCount - settlesBefore, 1, "one settle")
        XCTAssertEqual(afterRemoval.invocations.count, 0)
        XCTAssertEqual(try cacheKeys(), entriesBefore, "no entry for a removal")

        let record = try XCTUnwrap(engine.lastSettleRecord)
        let ran = try record.outcomes.keys.map { try database.node.select(nodeID: $0).kind }
        XCTAssertEqual(Set(ran), [ProjectFinder.kind], "only the finder runs")

        for kind in [CompilingSampleTool.kind, OutputFile.kind, ProjectBuilder.kind, StaticFile.kind] {
            XCTAssertEqual(try database.node.select(kind: kind).count, 0, "kind \(kind) is gone")
        }
        let folders = try database.node.select(kind: Folder.kind).compactMap { $0.properties[Folder.pathProperty] }
        XCTAssertTrue(Set(folders).isSubset(of: [Folder.inputFileSystemName, Folder.outputFileSystemName]), "\(folders)")
    }

    // MARK: - What a cache entry is written for

    private func material(inputs: [CacheKeyEntry]) -> CacheKeyMaterial {
        CacheKeyMaterial(nodeType: "SampleTool", implementationVersion: 1, properties: [], fingerprint: nil, inputs: inputs)
    }

    func test_aRunOverARemovedSourceIsNotWorthAnEntry() throws {
        let removedInput = material(inputs: [CacheKeyEntry(port: "input", wire: "a", value: .noValue(reason: .deleted))])

        XCTAssertFalse(SampleTool.isWorthStoring(outputValues: ["output": .value(try "result".intern())],
                                                 keyMaterial: removedInput))
    }

    func test_onlyCarriedStatesAreNotWorthAnEntry() throws {
        let plain = material(inputs: [CacheKeyEntry(port: "input", wire: "a", value: .value(try "a".intern()))])

        XCTAssertFalse(SampleTool.isWorthStoring(outputValues: ["output": .noValue(reason: .inputInError),
                                                                "log":    .noValue(reason: .inputNotProduced)],
                                                 keyMaterial: plain))
    }

    /// A tool's own failure is as much a function of its inputs as a value, and replaying
    /// it spares the run.
    func test_aToolsOwnFailureAndAWalkInProgressAreWorthAnEntry() throws {
        let plain    = material(inputs: [CacheKeyEntry(port: "input", wire: "a", value: .value(try "a".intern()))])
        let document = try ErrorDocument.engine(.noSources, subject: nil).published()

        XCTAssertTrue(SampleTool.isWorthStoring(outputValues: ["output": document,
                                                               "log":    .noValue(reason: .inputInError)],
                                                keyMaterial: plain))
        XCTAssertTrue(SampleTool.isWorthStoring(outputValues: ["output": .noValue(reason: .pending)],
                                                keyMaterial: plain))
    }
}
