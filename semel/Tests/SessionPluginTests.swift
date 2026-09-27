//
//  SessionPluginTests.swift
//  SemelCLITests
//
//  begin and commit over a scripted connection: a batch opened at the prompt holds the
//  engine's work signals until the commit, and the commit is also the wait.
//

@testable import SemelCLI
import SemelProtocol
import XCTest

final class SessionPluginTests: XCTestCase {

    private var connection: RecordingConnection!
    private var context: TestCommandContext!

    override func setUp() {
        super.setUp()
        connection = RecordingConnection()
        context    = TestCommandContext(connection: connection)
    }

    private func run(_ verb: String, _ tokens: [String] = []) throws {
        try SessionPlugin().handle(verb: verb, tokens: tokens, context: context)
    }

    func test_beginOpensABatchAndSaysNothing() throws {
        try run("begin")

        XCTAssertEqual(connection.daemonRequests, [.beginBatch])
        XCTAssertEqual(context.openBatchDepth, 1)
        XCTAssertEqual(context.allOutput, [])
    }

    /// A commit is the end of the batch and the wait for what it releases, in that order:
    /// the engine schedules on the end, and the wait sees that scheduling.
    func test_commitClosesTheBatchThenWaitsAndReportsSettled() throws {
        try run("begin")
        try run("commit")

        XCTAssertEqual(connection.daemonRequests, [.beginBatch, .endBatch, .wait])
        XCTAssertEqual(context.openBatchDepth, 0)
        XCTAssertEqual(context.messages, ["Settled."])
        XCTAssertEqual(context.errors, [])
    }

    /// The same guard `wait` keeps, placed between the end and the wait: the settle the
    /// end releases can fire and count during the wait request, so the accounting is
    /// clear before that request goes out — and not before the end, which would let a
    /// settle from earlier work count against this commit's wait.
    func test_commitResetsErrorAccountingBetweenTheEndAndTheWait() throws {
        let orderLog = OrderLog()
        connection.orderLog = orderLog
        context.orderLog    = orderLog

        try run("begin")
        try run("commit")

        XCTAssertEqual(orderLog.entries, ["send", "send", "resetErrorRecordAccounting", "settleWaitBegan", "send", "settleWaitEnded"])
    }

    /// Nested begins are one batch: the engine counts depth, so only the outermost commit
    /// releases it, and the client says so by waiting only then.
    func test_nestedBeginsNeedAsManyCommits() throws {
        try run("begin")
        try run("begin")
        try run("commit")

        XCTAssertEqual(context.openBatchDepth, 1)
        XCTAssertEqual(connection.daemonRequests, [.beginBatch, .beginBatch, .endBatch])
        XCTAssertEqual(context.messages, [])

        try run("commit")

        XCTAssertEqual(context.openBatchDepth, 0)
        XCTAssertEqual(connection.daemonRequests, [.beginBatch, .beginBatch, .endBatch, .endBatch, .wait])
        XCTAssertEqual(context.messages, ["Settled."])
    }

    /// A commit with nothing open is a script bug worth hearing about, and it sends
    /// nothing: an end without a begin is not the server's to absorb.
    func test_commitWithoutBeginIsAnErrorAndSendsNothing() throws {
        try run("commit")

        XCTAssertEqual(connection.daemonRequests, [])
        XCTAssertEqual(context.errors, ["commit: no batch is open"])
    }

    /// `discard` is not a verb: a batch cannot be undone once its pushes are in the input
    /// file system, and a discard that quietly committed would be worse than none.
    func test_discardIsNotAVerb() {
        XCTAssertFalse(SessionPlugin().verbs.contains("discard"))
    }
}
