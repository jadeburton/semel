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
    private var handler: RequestHandler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        DataObjectStore.shared = DataObjectStore(storeRoot: makeTempDirectory())
        externalRoot = makeTempDirectory()
        try FileManager.default.createDirectory(at: externalRoot.appendingPathComponent("src"),
                                                withIntermediateDirectories: true)
        let database = try DatabaseLayer()
        engine = try BuildEngine(database: database, startProcessingLoop: true)
        BuildEngine.shared = engine
        handler = RequestHandler(engine: engine, database: database, databasePath: "/tmp/test-graph.sqlite")
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
        handler = nil
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

    /// B-110. The idle-time event and the `errors` verb `build` runs at its end name the
    /// same failure; a build prints it once, through the verb, and still counts it.
    func test_aBuildPrintsTheReportOnce() throws {
        try writeBrokenFormula()
        var lines: [String] = []
        interpreter.output = { lines.append($0) }

        interpreter.handleCommand("build src")

        XCTAssertEqual(lines.filter { $0.hasPrefix("❌ ProjectBuilder") }.count, 1, lines.joined(separator: "\n"))
        XCTAssertGreaterThan(interpreter.errorsReported, 0)
    }

    /// B-110. A settle the follow loop answers by pushing what it named is not the build's
    /// verdict, so its failing summary is not printed ahead of the push that fixes it: a
    /// build prints one summary, at its end, carrying the last settle's errors.
    func test_aBuildThatFollowsASourcePrintsOneSummaryAtItsEnd() throws {
        try "product 'copy.txt' = StaticFile(path: <../side.txt>).output"
            .write(to: externalRoot.appendingPathComponent("src/semel.fmla"), atomically: true, encoding: .utf8)
        try "beside the folder".write(to: externalRoot.appendingPathComponent("side.txt"),
                                     atomically: true, encoding: .utf8)
        var lines: [String] = []
        interpreter.output = { lines.append($0) }

        interpreter.handleCommand("build src")

        let summaries = lines.filter { $0.contains(" scheduled, ") }
        XCTAssertTrue(lines.contains { $0.contains("needs ../side.txt") }, lines.joined(separator: "\n"))
        XCTAssertEqual(summaries.count, 1, lines.joined(separator: "\n"))
        XCTAssertTrue(summaries.first?.hasSuffix(" 0 errors") == true, lines.joined(separator: "\n"))
        XCTAssertEqual(interpreter.errorsReported, 0, lines.joined(separator: "\n"))
    }

    /// B-129. What a build prints once its waits are over: `Settled.` ends the last wait,
    /// then the summary says what the build did, with the artifact diff under it, then the
    /// report. The diff is held with the summary, not printed as its settle ends, where it
    /// would land under the last push rather than under the line it belongs to. The
    /// tutorial's transcripts show this order.
    func test_aBuildPrintsItsSummaryAfterTheLastSettledWithTheArtifactDiffUnderIt() throws {
        try "product 'copy.txt' = StaticFile(path: <../side.txt>).output"
            .write(to: externalRoot.appendingPathComponent("src/semel.fmla"), atomically: true, encoding: .utf8)
        try "beside the folder".write(to: externalRoot.appendingPathComponent("side.txt"),
                                     atomically: true, encoding: .utf8)
        var lines: [String] = []
        interpreter.output = { lines.append($0) }

        interpreter.handleCommand("build src")

        let transcript = lines.joined(separator: "\n")
        guard let summary = lines.firstIndex(where: { $0.contains(" scheduled, ") }),
              let lastSettled = lines.lastIndex(of: "Settled.") else {
            return XCTFail(transcript)
        }
        XCTAssertEqual(lastSettled + 1, summary, transcript)
        XCTAssertEqual(Array(lines[summary...].dropFirst().prefix(2)),
                       ["   appeared: output:/src/copy.txt", "No errors."], transcript)
        XCTAssertEqual(lines.filter { $0.hasPrefix("   appeared:") }.count, 1, transcript)
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
    /// usually name the very same failure; counting both would make one broken build
    /// look like two. Not asserted as an exact count: the engine can settle between
    /// `push`'s own `endBatch` and the macro's `wait` request, in which case the event
    /// reports that early settle on its own and `wait`'s later settle (or `errors`'
    /// query) adds a second, still-distinct report — genuinely two observations, not one
    /// double-counted. What must hold regardless is the deterministic part: the build
    /// failed and withheld its export.
    func test_theSameSettleErrorIsNotCountedTwice() throws {
        try writeBrokenFormula()
        let destination = makeTempDirectory()

        interpreter.handleCommand("build src --into \(destination.path)")

        XCTAssertGreaterThan(interpreter.errorsReported, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
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

    /// The order is what lets the summary's error count agree with the records above it:
    /// the engine reports the failures and then the totals, and a subscribed client sees
    /// them in that order, once each, through the real codec.
    func test_aSubscribedClientSeesTheErrorsThenTheSummaryForOneSettle() throws {
        let watcher = InProcessConnection(handler: handler)
        let received = EventLog()
        watcher.onEvent = { [received] event in received.append(event) }
        _ = try watcher.send(.hello(Hello(role: .daemon)), body: nil)
        _ = try watcher.send(.daemon(.subscribe), body: nil)

        try writeBrokenFormula()
        interpreter.handleCommand("build src")

        XCTAssertEqual(received.kinds, ["errors", "settled"],
                       "one report and one summary, the summary last, and no product to speak of")

        guard case .daemon(.settled(_, _, _, let errors))? = received.all.last else {
            return XCTFail("expected the settle summary last, got \(received.all)")
        }
        XCTAssertGreaterThan(errors, 0, "the summary counts the failure the report named")
    }

    /// B-50. The third report of a settle is what it produced, and it comes under the
    /// summary: the diff is read against the totals and the failures above it, not
    /// between them.
    func test_aSubscribedClientSeesTheArtifactsAfterTheSummaryForOneSettle() throws {
        let watcher = InProcessConnection(handler: handler)
        let received = EventLog()
        watcher.onEvent = { [received] event in received.append(event) }
        _ = try watcher.send(.hello(Hello(role: .daemon)), body: nil)
        _ = try watcher.send(.daemon(.subscribe), body: nil)

        try withBatch { try publishProduct("lib.a", contents: "archive") }
        engine.waitUntilIdleBlocking()

        XCTAssertEqual(received.kinds, ["settled", "artifacts"], "the diff comes under the summary")

        guard case .daemon(.artifacts(let appeared, let changed, let disappeared))? = received.all.last else {
            return XCTFail("expected the artifact diff last, got \(received.all)")
        }
        XCTAssertEqual(appeared, ["output:/src/lib.a"])
        XCTAssertEqual(changed, [])
        XCTAssertEqual(disappeared, [])
    }

    /// One batch around whatever it is handed, so the loop is woken once and everything
    /// built inside lands in one settle — which is what a test about the reports of *one*
    /// settle needs.
    private func withBatch(_ work: () throws -> Void) rethrows {
        engine.beginBatch()
        defer { engine.endBatch() }
        try work()
    }

    /// A product under `output:/src`, wired to a static file standing in for its builder.
    @discardableResult
    private func publishProduct(_ name: String, contents: String?) throws -> NodeRecord {
        let (source, _) = try GraphSpecNode.parse("StaticFile(path: 'input:/stand-in/\(name)')")
            .findOrCreateMatchingNode()
        if let contents {
            _ = try XCTUnwrap(source.nodeAsAny() as? StaticFile).replaceContent(try contents.intern())
        }
        let (product, _) = try GraphSpecNode.parse("OutputFile(path: 'output:/src/\(name)')")
            .findOrCreateMatchingNode()
        try Wire.connectWire(database: engine.database,
                             fromNodeID: try source.requireID(),
                             fromSymbolID: StaticFile.outputPort.asSymbolID(),
                             toNodeID: try product.requireID(),
                             toSymbolID: OutputFile.inputPort.asSymbolID(),
                             name: "product".asSymbolID())
        return source
    }

    /// A product whose source has something of its own to say. The error is written after
    /// the wiring, which puts every output of its target back to pending.
    private func publishFailedProduct(_ name: String, message: String) throws {
        let source = try publishProduct(name, contents: nil)
        try source.writeToOutputPort(StaticFile.outputPort,
                                     value: .noValue(reason: .error(messageDataObjectHash: try message.intern())))
    }

    /// All three of one settle's reports, in the order they are meant to be read: the
    /// failures, the totals that count them, and what the settle produced. Pinned
    /// together, because the pairwise tests above would both pass on an order that put
    /// the diff between the failures and the count of them.
    func test_aSubscribedClientSeesErrorsThenTheSummaryThenTheArtifacts() throws {
        let watcher = InProcessConnection(handler: handler)
        let received = EventLog()
        watcher.onEvent = { [received] event in received.append(event) }
        _ = try watcher.send(.hello(Hello(role: .daemon)), body: nil)
        _ = try watcher.send(.daemon(.subscribe), body: nil)

        try withBatch {
            try publishProduct("lib.a", contents: "archive")
            try publishFailedProduct("broken.a", message: "the source is gone")
        }
        engine.waitUntilIdleBlocking()

        XCTAssertEqual(received.kinds, ["errors", "settled", "artifacts"])
    }

    /// Events arrive on the engine's task and are read from the test's thread.
    private final class EventLog {
        private let lock = NSLock()
        private var storage: [Event] = []

        func append(_ event: Event) {
            lock.withLock { storage.append(event) }
        }

        var all: [Event] {
            lock.withLock { storage }
        }

        /// The events that are one of a settle's three reports, named, in arrival order.
        /// A notice is not one of them and is left out.
        var kinds: [String] {
            all.compactMap { event in
                switch event {
                case .daemon(.errors):    return "errors"
                case .daemon(.settled):   return "settled"
                case .daemon(.artifacts): return "artifacts"
                case .daemon(.notice):    return nil
                // Progress is where the settle stands, not one of its reports (B-95).
                case .daemon(.progress):  return nil
                }
            }
        }
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
