//
//  UnlinkedKindTests.swift
//  SemelCoreTests
//
//  B-130. A graph outlives the server that built it: a type removed from `semelserv` —
//  the tutorial's `MyLineCounter`, a plugin left out of a build — leaves rows whose kind
//  nothing links. Such a node cannot run, so what it publishes when woken is an error
//  naming its kind and the way out; everything around it goes on as usual. The kind is
//  rewritten on a row here, which is what a server that stopped linking the type sees.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class UnlinkedKindTests: SemelCoreTestCase {

    private var engine: BuildEngine!
    private var captured: [[ErrorReport.Entry]] = []
    private var database: DatabaseLayer { engine.database }

    /// A kind no type claims, as a removed type's number is to a server built without it.
    private let unlinkedKind: UInt = 999_999

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
        engine.errorReporter = { [weak self] entries in self?.captured.append(entries) }
    }

    override func tearDown() {
        // A loop left running would keep processing against the next test's globals.
        engine.stopProcessingLoop()
        engine.waitUntilIdleBlocking()
        engine = nil
        captured = []
        super.tearDown()
    }

    // MARK: - Helpers

    /// The push `semel push` makes of one file.
    @discardableResult
    private func push(_ text: String, to relativePath: String = "src/a.txt") throws -> Bool {
        try StaticFile.push(Array(text.utf8), mode: FileMetadata.defaultMode, at: Path(relativePath))
    }

    private func demanding(tag: String, reading inputs: [String: GraphSpecNode]) -> GraphSpecNode {
        GraphSpecNode(DemandingSampleTool.self, properties: ["tag": tag],
                      inputs: [DemandingSampleTool.input: inputs]).port(DemandingSampleTool.output)
    }

    /// The node that goes unlinked, reading the pushed file, and a reader of it: the shape
    /// the tutorial leaves, its counter between the sources and the product. A sibling reads
    /// the same file beside it, made after it so that its wire is the later one a push walks.
    private struct Chain {
        let stale:   ObjectID
        let reader:  ObjectID
        let sibling: ObjectID
    }

    private func makeChain() throws -> Chain {
        try push("one")
        let staleTree   = demanding(tag: "stale", reading: ["a": .staticFile(at: "input:/src/a.txt")])
        let readerTree  = demanding(tag: "reader", reading: ["counted": staleTree])
        let siblingTree = demanding(tag: "sibling", reading: ["a": .staticFile(at: "input:/src/a.txt")])
        let stale   = try staleTree.findOrCreateMatchingNode().fromNode.requireID()
        let reader  = try readerTree.findOrCreateMatchingNode().fromNode.requireID()
        let sibling = try siblingTree.findOrCreateMatchingNode().fromNode.requireID()
        return Chain(stale: stale, reader: reader, sibling: sibling)
    }

    /// What a server that no longer links the node's type finds in the row.
    private func unlink(_ nodeID: ObjectID) throws {
        var nodeRecord = try database.node.select(nodeID: nodeID)
        nodeRecord.kind = unlinkedKind
        try database.node.update(nodeRecord)
    }

    private func value(of nodeID: ObjectID) throws -> NodeValue {
        let port = try XCTUnwrap(try database.outputPort.select(nodeID: nodeID,
                                                                nameSymbolID: DemandingSampleTool.output.asSymbolID()))
        return try port.asNodeValue()
    }

    private func settle() async {
        engine.signalWorkAvailable()
        await engine.waitUntilIdle()
    }

    // MARK: - The push

    /// The push that wakes it is a push like any other: it stores the file, says it
    /// changed, and wakes every other reader of the file, including those whose wires come
    /// after the stale node's.
    func test_aPushThatWakesANodeOfAnUnlinkedKindStoresTheFileAndWakesEveryReader() async throws {
        let chain = try makeChain()
        engine.startProcessingLoop()
        await engine.waitUntilIdle()
        try unlink(chain.stale)

        XCTAssertTrue(try push("two"))
        await settle()

        guard case .value(let hash) = try value(of: chain.sibling) else {
            return XCTFail("expected the sibling to have run, got \(try value(of: chain.sibling))")
        }
        XCTAssertEqual(try hash.resolveAsString(), "two")
    }

    // MARK: - What it publishes

    /// Woken, it publishes an error naming its kind and `reset`, and its reader carries it:
    /// the build fails with a real error, named at the node, rather than settling clean.
    func test_aWokenNodeOfAnUnlinkedKindCarriesAnErrorTheReportNamesAtIt() async throws {
        let chain = try makeChain()
        engine.startProcessingLoop()
        await engine.waitUntilIdle()
        try unlink(chain.stale)

        try push("two")
        await settle()

        let staleValue = try value(of: chain.stale)
        let document = try XCTUnwrap(staleValue.errorDocument, "expected an error on the node, got \(staleValue)")
        XCTAssertEqual(document.diagnostic, .engine(.unlinkedKind(kind: unlinkedKind)))
        XCTAssertEqual(document.remedy, .register(kind: unlinkedKind))
        guard case .noValue(.inputInError) = try value(of: chain.reader) else {
            return XCTFail("expected the reader to carry it, got \(try value(of: chain.reader))")
        }

        // What `errors` answers, and what `build` prints at its end.
        let entries = ErrorReport.entries(forErrorPorts: try ErrorReport.portsToReport(database: database),
                                          database: database,
                                          select: { _, documents in documents })
        XCTAssertEqual(entries.map(\.label), ["kind \(unlinkedKind) #\(chain.stale)"])
        XCTAssertEqual(entries.first?.downstreamCarrierCount, 1, "the reader, folded onto its cause")
        XCTAssertEqual(entries.first?.items.map(\.document), [document])
        XCTAssertEqual(entries.first?.typeName, "kind \(unlinkedKind)")
    }

    /// A node left scheduled when the server stopped is picked up by the first pass after
    /// the restart, which cannot run it either: it is settled as its error, not left
    /// pending with every reader waiting on it.
    func test_aNodeOfAnUnlinkedKindLeftScheduledSettlesAsItsError() async throws {
        let chain = try makeChain()
        try unlink(chain.stale)
        try database.node.updateScheduled(nodeID: chain.stale, scheduled: true)

        engine.startProcessingLoop()
        await engine.waitUntilIdle()

        guard case .noValue(.error) = try value(of: chain.stale) else {
            return XCTFail("expected an error on the node, got \(try value(of: chain.stale))")
        }
        XCTAssertFalse(try database.node.select(nodeID: chain.stale).scheduled)
    }

    // MARK: - Letting it go

    /// Nothing but a pushed file or folder is kept for its own sake, and those are the
    /// engine's own types, always linked. So a node of a kind this server does not link is
    /// collected like any other once nothing reads it: taking it out of the formula is
    /// enough, and no `reset` is needed.
    func test_aNodeOfAnUnlinkedKindIsCollectedOnceNothingReadsIt() throws {
        let chain = try makeChain()
        try unlink(chain.stale)

        for wire in try database.wire.select(goingToNodeID: chain.reader) {
            try wire.deleteWire(database: database)
        }
        while try engine.processPendingDeletions() > 0 {}

        XCTAssertNil(try database.node.find(nodeID: chain.stale))
        let file = try XCTUnwrap(try engine.inputFileSystem.childNode(path: "src/a.txt"))
        XCTAssertEqual(try database.wire.select(comingFromNodeID: try file.requireID()).map(\.toNodeID), [chain.sibling],
                       "the file stays, read by the sibling alone")
    }
}
