//
//  CascadeReportScaleTests.swift
//  SemelCoreTests
//
//  B-74's second half. `CascadeCollapseTests` pins what the fold *says*; this file pins
//  what it costs. The report's upstream walk asks the graph one indexed wire query per
//  carrying node, and a cascade is all carriers — so the question the entry was opened by
//  is whether that count follows the cascade or the square of it.
//
//  Asserted as a count of queries, not as seconds, for the reason `FolderRemovalScaleTests`
//  gives: a stopwatch has to be given a band wide enough to survive a loaded machine, and
//  such a band stops telling linear from quadratic long before the difference stops
//  mattering. The seconds are measured all the same and quoted in the failure message, so
//  a count that has held while the walk got slower still says so on the page.
//

@testable import SemelCore
@testable import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class CascadeReportScaleTests: SemelCoreTestCase {

    /// The two cascade sizes every growth test uses. Quadruple the consumers: a linear walk
    /// quadruples its queries, a quadratic one multiplies them by sixteen, and the two are
    /// far enough apart that no allowance has to be argued over. The larger is close to the
    /// 500-node cascade B-74 was opened by.
    private static let sizes = (small: 100, large: 400)

    // MARK: - Growth

    /// The walk visits each carrying node once and asks it one question, however many
    /// carriers share an answer, and the report it feeds is one record however wide the
    /// cascade. Memoisation is what makes the first true: without it the sink re-walks
    /// every consumer's chain and the count follows the square of the cascade.
    ///
    /// Both sizes are built once, for both claims: the fixture is the expensive part of
    /// this file, and a test apiece would build four cascades to measure two.
    func test_theUpstreamWalkCostsAtMostOneWireQueryPerCarryingNode() throws {
        let small = try walkOfACascadeOf(Self.sizes.small)
        let large = try walkOfACascadeOf(Self.sizes.large)

        // Every node below the failing source carries the cascade: the consumers and the
        // sink they feed. The source itself is a cause and is never walked.
        XCTAssertLessThanOrEqual(small.queries, small.consumers + 1, small.described)
        XCTAssertLessThanOrEqual(large.queries, large.consumers + 1, large.described)

        // Four times the cascade, at most four times the queries. Stated as a bound rather
        // than an equality so that batching the query — the next step B-74 names, and the
        // one that would take the count below one per node — improves this test instead of
        // breaking it.
        let ratio = Self.sizes.large / Self.sizes.small
        XCTAssertLessThanOrEqual(large.queries, ratio * small.queries,
                                 "the walk must not grow faster than the cascade — "
                                 + "\(small.described); \(large.described)")

        // The whole point of the fold, at a size where the unfolded report would be
        // hundreds of lines: one failing source, one record, whatever hangs off it.
        XCTAssertEqual(small.records, 1, small.described)
        XCTAssertEqual(large.records, 1, large.described)
    }

    // MARK: - What one walk cost

    /// The wire queries one upstream walk issued, the records the report it fed came to,
    /// and the seconds it took — which are carried for a failure message to quote and are
    /// never asserted on.
    private struct WalkCost {
        let consumers: Int
        let queries:   Int
        let records:   Int
        let seconds:   TimeInterval

        var described: String {
            "\(consumers) consumers: \(queries) wire queries, \(records) record(s)"
            + " in \(String(format: "%.3f", seconds))s"
        }
    }

    /// Builds a cascade of `consumers` in a database of its own, then measures the walk
    /// alone: the ports and what the sources have to say for themselves are worked out
    /// first, so the only queries inside the window are the ones the fold issues.
    private func walkOfACascadeOf(_ consumers: Int) throws -> WalkCost {
        let engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
        let database = engine.database

        try buildCascade(consumers: consumers, database: database)

        let ports   = try ErrorReport.portsToReport(database: database)
        let byNode  = Dictionary(grouping: ports, by: \.nodeID)
        let sourced = ErrorReport.sourceMessages(amongPorts: ports, database: database)

        let queriesBefore = WireDataAccess.selectCount
        let start  = Date.now
        let counts = ErrorReport.causes(amongErrorPorts: byNode,
                                        database: database,
                                        sourceMessages: sourced)
        let seconds = Date.now.timeIntervalSince(start)
        let queries = WireDataAccess.selectCount - queriesBefore

        // The report the walk feeds, built outside the measured window: a record per cause,
        // which is what the reader is handed.
        let records = ErrorReport.entries(forErrorPorts: ports,
                                          database: database,
                                          sourceMessages: sourced) { _, messages in messages }

        XCTAssertEqual(counts.count, records.count, "every cause reaches the report")

        return WalkCost(consumers: consumers,
                        queries: queries,
                        records: records.count,
                        seconds: seconds)
    }

    // MARK: - The graph

    /// The shape `test_aCascadeIsReportedAsItsCauseAlone` uses, at scale: one failing
    /// source, a consumer per unit of width reading it, and one sink reading every
    /// consumer. Everything below the source carries, so the graph holds
    /// `consumers + 2` failing nodes and exactly one cause.
    private func buildCascade(consumers: Int, database: DatabaseLayer) throws {
        let sourceTree = GraphSpecNode.staticFile(at: "input:/shared.h")
        var parts: [String: GraphSpecNode] = [:]
        for index in 0 ..< consumers {
            parts["part \(index)"] = consumer(tag: "consumer \(index)", reading: ["header": sourceTree])
        }
        let (sink, _) = try consumer(tag: "sink", reading: parts).findOrCreateMatchingNode()
        let source    = try sourceTree.findOrCreateMatchingNode().fromNode.requireID()

        var carriers = [try sink.requireID()]
        for wire in try database.wire.select(goingToNodeID: try sink.requireID()) {
            carriers.append(wire.fromNodeID)
        }

        try database.node.select(nodeID: source)
            .writeToOutputPort("output",
                               value: .noValue(reason: .error(messageDataObjectHash:
                                                              try "the file is gone".intern())))
        for carrier in carriers {
            try database.node.select(nodeID: carrier)
                .writeToOutputPort("output", value: .noValue(reason: .inputInError))
        }
    }

    /// A node with no path of its own reading `inputs` by wire name, read at `output`, the
    /// port the states above are written to.
    private func consumer(tag: String, reading inputs: [String: GraphSpecNode]) -> GraphSpecNode {
        GraphSpecNode(TreeMerger.self, properties: ["tag": tag], inputs: [TreeMerger.inputPort: inputs]).port("output")
    }
}
