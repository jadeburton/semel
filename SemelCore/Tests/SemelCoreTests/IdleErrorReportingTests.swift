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

    private func makeFailingFile(path: String, message: String) throws {
        let nodeRecord = try NodeRecord.createNode(database: engine.database,
                                                   kind: StaticFile.kind,
                                                   properties: ["path": path],
                                                   graphSpec: nil)
        try nodeRecord.writeToOutputPort("output",
                                         value: .noValue(reason: .error(messageDataObjectHash: try message.intern())))
    }

    func test_aNewErrorReachesTheReporterAsAnEntry() throws {
        try makeFailingFile(path: "input:/a.c", message: "boom")

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0].map(\.label), ["StaticFile  'input:/a.c'"])
        XCTAssertEqual(captured[0][0].items, [ErrorReport.Item(ports: ["output"], message: "boom")])
    }

    func test_anErrorAlreadyReportedIsNotReportedAgain() throws {
        try makeFailingFile(path: "input:/a.c", message: "boom")

        engine.reportIdleTimeErrors()
        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured.count, 1)
    }

    func test_nothingIsReportedWhenThereAreNoErrors() throws {
        engine.reportIdleTimeErrors()

        XCTAssertTrue(captured.isEmpty)
    }

    /// The lines the default reporter prints are the same lines `ErrorReport` has always
    /// produced, so an engine run without a server reads as before.
    func test_renderingAnEntryMatchesTheReportFormat() throws {
        let entry = ErrorReport.Entry(label: "StaticFile  'input:/a.c'",
                                      items: [ErrorReport.Item(ports: ["errorLog", "output"], message: "boom")])

        XCTAssertEqual(ErrorReport.lines(for: entry),
                       ["❌ StaticFile  'input:/a.c'", "   · errorLog, output: boom", ""])
    }

    func test_aNoticeReachesTheNoticeReporter() {
        var notices: [String] = []
        engine.noticeReporter = { notices.append($0) }

        BuildEngine.notice("output:/app: written")

        XCTAssertEqual(notices, ["output:/app: written"])
    }
}
