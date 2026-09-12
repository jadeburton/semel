//
//  ErrorReportTests.swift
//  SemelCoreTests
//
//  How a node's errors read.
//
//  Two callers render this — the engine as it settles, and the CLI's `errors` command on
//  request. They differ in which errors they select, never in how those errors look, and
//  these tests are what keeps that true now that both go through one function.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class ErrorReportTests: SemelCoreTestCase {

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

    private func makeNode(kind: UInt, properties: [String: String] = [:]) throws -> ObjectID {
        try NodeRecord.createNode(database: database, kind: kind,
                            properties: properties, graphSpec: nil).requireID()
    }

    private func port(_ nodeID: ObjectID, _ name: String, _ message: String) throws -> OutputPort {
        OutputPort(nodeID: nodeID,
                   nameSymbolID: name.asSymbolID(),
                   valueKind: .error,
                   dataObjectHash: try message.intern())
    }

    // MARK: - Grouping

    /// A node that fails usually fails on every port at once for the same reason. Naming the
    /// ports together says that in one line; a line per port says the same thing three times
    /// and hides how many distinct problems there actually are.
    func test_portsSharingAMessageAreNamedTogether() throws {
        let nodeID = try makeNode(kind: Configuration.kind)
        let ports = [try port(nodeID, "output", "boom"),
                     try port(nodeID, "infoLog", "boom"),
                     try port(nodeID, "errorLog", "boom")]

        let lines = ErrorReport.lines(forNodeID: nodeID, ports: ports,
                                      messages: ["boom"], database: database)

        XCTAssertEqual(lines.filter { $0.contains("·") },
                       ["   · errorLog, infoLog, output: boom"])
    }

    func test_distinctMessagesGetTheirOwnLines() throws {
        let nodeID = try makeNode(kind: Configuration.kind)
        let ports = [try port(nodeID, "output", "first"),
                     try port(nodeID, "infoLog", "second")]

        let lines = ErrorReport.lines(forNodeID: nodeID, ports: ports,
                                      messages: ["first", "second"], database: database)

        XCTAssertEqual(lines.filter { $0.contains("·") },
                       ["   · output: first", "   · infoLog: second"])
    }

    /// Sorted, so the same failure reads the same way twice. Set iteration order is seeded
    /// per process, so without this a report would shuffle between runs.
    func test_messagesAndPortNamesAreSorted() throws {
        let nodeID = try makeNode(kind: Configuration.kind)
        let ports = [try port(nodeID, "zebra", "b"), try port(nodeID, "alpha", "b"),
                     try port(nodeID, "middle", "a")]

        let lines = ErrorReport.lines(forNodeID: nodeID, ports: ports,
                                      messages: ["b", "a"], database: database)

        XCTAssertEqual(lines.filter { $0.contains("·") },
                       ["   · middle: a", "   · alpha, zebra: b"])
    }

    // MARK: - Multi-line messages

    /// A missing-configuration error spans several lines and is the most common multi-line
    /// case there is, so it has to stay readable rather than being folded onto one line.
    func test_aMultiLineMessageIsIndentedUnderItsPorts() throws {
        let nodeID = try makeNode(kind: Configuration.kind)
        let message = "Missing configuration. Add these:\n\nclang.compiler.target=…\n"
        let ports = [try port(nodeID, "output", message)]

        let lines = ErrorReport.lines(forNodeID: nodeID, ports: ports,
                                      messages: [message], database: database)

        XCTAssertEqual(Array(lines[1 ..< lines.count - 1]),
                       ["   · output:",
                        "     Missing configuration. Add these:",
                        "     clang.compiler.target=…"])
    }

    // MARK: - Labels

    func test_aNodeWithAPathIsNamedByIt() throws {
        let nodeID = try makeNode(kind: StaticFile.kind, properties: ["path": "input:/a/b.c"])

        XCTAssertEqual(ErrorReport.label(forNodeID: nodeID, database: database),
                       "StaticFile  'input:/a/b.c'")
    }

    /// The internal id is a surrogate integer and means nothing to the reader, so it appears
    /// only when nothing better can be found.
    func test_anUnreadableNodeFallsBackToItsID() throws {
        XCTAssertEqual(ErrorReport.label(forNodeID: 99999, database: database), "Node 99999")
    }

    // MARK: - What counts as reportable

    /// Every node holds "initializing" between being created and first processing, so
    /// reporting it would announce an error for every node in a fresh graph.
    func test_theInitializingPlaceholderIsNotReportable() throws {
        let nodeID = try makeNode(kind: Configuration.kind)

        XCTAssertNil(ErrorReport.reportableMessage(of: try port(nodeID, "output", "initializing")))
        XCTAssertNil(ErrorReport.reportableMessage(of: try port(nodeID, "output", "")))
        XCTAssertEqual(ErrorReport.reportableMessage(of: try port(nodeID, "output", "real")), "real")
    }
}
