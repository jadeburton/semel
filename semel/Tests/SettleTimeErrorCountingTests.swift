//
//  SettleTimeErrorCountingTests.swift
//  SemelCLITests
//
//  B-82: a formula naming a node type nothing registers fails only once the engine
//  actually processes it, which is what the idle-time settle report tells the client
//  about through an event — not through the explicit `errors` verb. These tests need a
//  *live* processing loop: an error created synchronously at node creation, like
//  `BuildCommandTests`' `unfed.a`, never exercises that event at all.
//

@testable import SemelCLI
@testable import SemelCore
import Foundation
import SemelNodeKit
import SemelProtocol
import SemelServer
import XCTest

final class SettleTimeErrorCountingTests: XCTestCase {

    private var engine: BuildEngine!
    private var interpreter: CommandInterpreter!
    private var externalRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        DataObjectStore.shared = DataObjectStore(storeRoot: makeTempDirectory())
        externalRoot = makeTempDirectory()
        try FileManager.default.createDirectory(at: externalRoot.appendingPathComponent("src"),
                                                withIntermediateDirectories: true)
        let database = try DatabaseLayer()
        engine = try BuildEngine(database: database, startProcessingLoop: true)
        BuildEngine.shared = engine
        let handler = RequestHandler(engine: engine, database: database, databasePath: "/tmp/test-graph.sqlite")
        let connection = InProcessConnection(handler: handler)
        interpreter = CommandInterpreter(connection: connection, baseDirectory: externalRoot.path)
        // Subscribes, so the settle-time event this suite is about actually reaches the
        // interpreter — real usage always subscribes, from `connect()`.
        _ = try interpreter.connect()
        engine.waitUntilIdleBlocking()
    }

    override func tearDown() {
        engine.stopProcessingLoop()
        engine = nil
        BuildEngine.shared = nil
        interpreter = nil
        super.tearDown()
    }

    private func makeTempDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-cli-tests/\(UUID().uuidString)", isDirectory: true)
    }

    private func writeBrokenFormula() throws {
        try """
            product 'broken' =
                NoSuchNodeType(role: 'x').output
            """.write(to: externalRoot.appendingPathComponent("src/semel.fmla"),
                      atomically: true, encoding: .utf8)
    }

    /// The failure that reaches the user only through the idle-time event: `wait` alone,
    /// with no `errors` afterward, is what a script that just checks the build settled —
    /// not what it printed — would run.
    func test_aFormulaErrorReportedOnlyAtSettleIsCounted() throws {
        try writeBrokenFormula()

        interpreter.handleCommand("push src")
        interpreter.handleCommand("wait")

        XCTAssertGreaterThan(interpreter.errorsReported, 0)
    }

    /// `build --into` is what ships a product: an error surfacing only at settle must
    /// still fail the build and withhold the export.
    func test_buildWithASettleTimeErrorExportsNothingAndReportsFailure() throws {
        try writeBrokenFormula()
        let destination = makeTempDirectory()

        interpreter.handleCommand("build src --into \(destination.path)")

        XCTAssertGreaterThan(interpreter.errorsReported, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    /// The idle-time event and the `errors` verb the `build` macro runs right after it
    /// name the very same failure; counting both would make one broken build look like
    /// two.
    func test_theSameSettleErrorIsNotCountedTwice() throws {
        try writeBrokenFormula()

        interpreter.handleCommand("build src")

        XCTAssertEqual(interpreter.errorsReported, 1)
    }

    /// A second `build` against a graph that is still broken the same way must still
    /// refuse to export, even though the engine's own idle-time report will not repeat a
    /// message it already delivered once and so the event will not fire a second time —
    /// only the `errors` verb's own query still sees it.
    func test_aSecondBuildAgainstTheSameBrokenGraphStillSkipsExport() throws {
        try writeBrokenFormula()
        let firstDestination  = makeTempDirectory()
        let secondDestination = makeTempDirectory()

        interpreter.handleCommand("build src --into \(firstDestination.path)")
        let errorsAfterFirstBuild = interpreter.errorsReported
        interpreter.handleCommand("build src --into \(secondDestination.path)")

        XCTAssertGreaterThan(interpreter.errorsReported, errorsAfterFirstBuild)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondDestination.path))
    }

    /// The live loop runs `reportIdleTimeErrors` on every idle pass; a report with
    /// nothing in it must not be mistaken for a report naming an error.
    func test_aCleanBuildLeavesErrorsReportedAtZero() throws {
        try "int main(void) { return 0; }".write(
            to: externalRoot.appendingPathComponent("src/main.c"), atomically: true, encoding: .utf8)

        interpreter.handleCommand("build src")

        XCTAssertEqual(interpreter.errorsReported, 0)
    }
}
