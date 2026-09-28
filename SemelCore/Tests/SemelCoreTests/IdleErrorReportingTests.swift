//
//  IdleErrorReportingTests.swift
//  SemelCoreTests
//
//  The idle-time error report goes through a closure so that a server can carry it to a
//  client instead of it landing on whichever stdout the engine happens to have. The
//  default still prints; these tests install a capturing closure instead.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class IdleErrorReportingTests: SemelCoreTestCase {

    private var engine: BuildEngine!
    private var captured: [[ErrorReport.Entry]] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
        engine.errorReporter = { [weak self] entries in self?.captured.append(entries) }
    }

    override func tearDown() {
        engine = nil
        captured = []
        super.tearDown()
    }

    @discardableResult
    private func makeFailingFile(path: String, message: String) throws -> ObjectID {
        let (nodeRecord, _) = try GraphSpecNode.staticFile(at: path).findOrCreateMatchingNode()
        try nodeRecord.writeToOutputPort("output",
                                         value: .noValue(reason: .error(messageDataObjectHash: try message.intern())))
        return try nodeRecord.requireID()
    }

    func test_aNewErrorReachesTheReporterAsAnEntry() throws {
        let file = try makeFailingFile(path: "input:/a.c", message: "boom")

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0].map(\.label), ["StaticFile #\(file) 'input:/a.c'"])
        XCTAssertEqual(captured[0][0].items, [ErrorReport.Item(ports: ["output"], message: "boom")])
    }

    func test_anErrorAlreadyReportedIsNotReportedAgain() throws {
        try makeFailingFile(path: "input:/a.c", message: "boom")

        engine.reportIdleTimeErrors()
        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured.count, 1)
    }

    /// What is newly appearing decides what is printed; what is currently wrong decides
    /// what is counted. A rebuild that breaks the same node the same way prints nothing
    /// new and still counts the failure, so the settle summary cannot say "0 errors" over
    /// a graph the `errors` command calls broken.
    func test_aStandingErrorIsCountedOnEverySettleThoughItIsReportedOnce() throws {
        try makeFailingFile(path: "input:/a.c", message: "boom")

        XCTAssertEqual(engine.reportIdleTimeErrors(), 1)
        XCTAssertEqual(engine.reportIdleTimeErrors(), 1, "the graph is still broken")
        XCTAssertEqual(captured.count, 1, "and the reader has been told once")
    }

    /// Counted per port, which is what the `errors` command calls an error: one node
    /// failing on two ports is two.
    func test_theCountIsPerPortAndNotPerNode() throws {
        let (nodeRecord, _) = try GraphSpecNode.staticFile(at: "input:/a.c").findOrCreateMatchingNode()
        for port in ["output", "errorLog"] {
            try nodeRecord.writeToOutputPort(port,
                                             value: .noValue(reason: .error(messageDataObjectHash: try "boom".intern())))
        }

        XCTAssertEqual(engine.reportIdleTimeErrors(), 2)
    }

    func test_nothingIsReportedWhenThereAreNoErrors() throws {
        engine.reportIdleTimeErrors()

        XCTAssertTrue(captured.isEmpty)
    }

    // MARK: - Nodes of one type carrying one report (B-110)

    private func makeFailingMerger(tag: String, message: String) throws -> ObjectID {
        let (nodeRecord, _) = try GraphSpecNode(TreeMerger.self, properties: ["tag": tag]).findOrCreateMatchingNode()
        try nodeRecord.writeToOutputPort(TreeMerger.outputPort,
                                         value: .noValue(reason: .error(messageDataObjectHash: try message.intern())))
        return try nodeRecord.requireID()
    }

    /// Eight compilers missing the same settings are one paragraph that says which eight.
    func test_nodesOfOneTypeCarryingOneReportAreOneEntryNamingThemAll() throws {
        let first  = try makeFailingMerger(tag: "a", message: "boom")
        let second = try makeFailingMerger(tag: "b", message: "boom")
        let third  = try makeFailingMerger(tag: "c", message: "boom")
        let other  = try makeFailingMerger(tag: "d", message: "another thing")

        engine.reportIdleTimeErrors()

        let ids = [first, second, third].sorted().map { "#\($0)" }.joined(separator: ", ")
        XCTAssertEqual(captured[0].map(\.label), ["TreeMerger ×3 (\(ids))", "TreeMerger #\(other)"])
        XCTAssertEqual(captured[0][0].nodeCount, 3)
        XCTAssertEqual(captured[0][0].items, [ErrorReport.Item(ports: ["files"], message: "boom")])
        XCTAssertEqual(captured[0][1].nodeCount, 1)
    }

    /// A node with a path is one the reader acts on by that path, so two of them stay two
    /// entries however alike their messages.
    func test_twoFilesCarryingOneMessageStayTwoEntries() throws {
        let first  = try makeFailingFile(path: "input:/a.c", message: "gone")
        let second = try makeFailingFile(path: "input:/b.c", message: "gone")

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured[0].map(\.label),
                       ["StaticFile #\(first) 'input:/a.c'", "StaticFile #\(second) 'input:/b.c'"])
    }

    /// The lines the default reporter prints are the same lines `ErrorReport` has always
    /// produced, so an engine run without a server reads as before.
    func test_renderingAnEntryMatchesTheReportFormat() throws {
        let entry = ErrorReport.Entry(label: "StaticFile #7 'input:/a.c'",
                                      items: [ErrorReport.Item(ports: ["errorLog", "output"], message: "boom")])

        XCTAssertEqual(ErrorReport.lines(for: entry),
                       ["❌ StaticFile #7 'input:/a.c'", "   · errorLog, output: boom", ""])
    }

    func test_aNoticeReachesTheNoticeReporter() {
        var notices: [String] = []
        engine.noticeReporter = { notices.append($0) }

        BuildEngine.notice("output:/app: written")

        XCTAssertEqual(notices, ["output:/app: written"])
    }
}
