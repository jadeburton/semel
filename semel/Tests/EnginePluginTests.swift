//
//  EnginePluginTests.swift
//  SemelCLITests
//
//  errors, reset, nudge, debug and tools over a scripted connection: what each sends and
//  how it renders what comes back.
//

@testable import SemelCLI
import SemelProtocol
import XCTest

final class EnginePluginTests: XCTestCase {

    private var connection: RecordingConnection!
    private var context: TestCommandContext!

    override func setUp() {
        super.setUp()
        connection = RecordingConnection()
        context    = TestCommandContext(connection: connection)
    }

    private func run(_ verb: String, _ tokens: [String] = []) throws {
        try EnginePlugin().handle(verb: verb, tokens: tokens, context: context)
    }

    /// The sentence every reset ends with: the repair points at the command that says what
    /// was wrong before the next one destroys the evidence.
    private static let checkOffer =
        "Run `check` before the next reset: it names the invariants a graph is breaking — "
      + "the evidence a reset discards."

    func test_errorsWithNoneSaysSo() throws {
        connection.reply(.errors(records: []))

        try run("errors")

        XCTAssertEqual(connection.daemonRequests, [.errors])
        XCTAssertEqual(context.messages, ["No errors."])
    }

    func test_errorsRendersRecordsUnderACount() throws {
        connection.reply(.errors(records: [
            ErrorRecord(label: "StaticFile #12 'input:/a.c'", entries: [ErrorEntry(ports: ["errorLog", "output"], message: "boom")]),
        ]))

        try run("errors")

        // The count goes through `countErrorRecords`, not `outputError`, so the same
        // settle report the idle-time event already counted is not counted twice. It is a
        // sum of ports, which is why the line keeps their names: two errors, two ports.
        XCTAssertEqual(context.messages, [
            "2 errors across 1 node:\n",
            "❌ StaticFile #12 'input:/a.c'",
            "   · errorLog, output: boom",
            "",
        ])
        XCTAssertEqual(context.countedErrorRecords, [[
            ErrorRecord(label: "StaticFile #12 'input:/a.c'", entries: [ErrorEntry(ports: ["errorLog", "output"], message: "boom")]),
        ]])
    }

    /// A missing-configuration message spans lines and carries the config lines the reader
    /// has to paste, so it prints as an indented block rather than folded onto one line.
    /// This is the path a node's error takes once it arrives as the words
    /// the node wrote instead of as the debug form of the case carrying them.
    func test_errorsPrintsAMultiLineMessageAsAnIndentedBlock() throws {
        let message = """
            Missing configuration. Add these to a semel.config in the input file system:

            clang.linker.target=…
            """
        connection.reply(.errors(records: [
            ErrorRecord(label: "ClangLinker #12 'input:/semel.fmla'",
                        entries: [ErrorEntry(ports: ["output"], message: message)]),
        ]))

        try run("errors")

        XCTAssertEqual(context.messages, [
            "1 error across 1 node:\n",
            "❌ ClangLinker #12 'input:/semel.fmla'",
            "   · Missing configuration. Add these to a semel.config in the input file system:",
            "     clang.linker.target=…",
            "",
        ])
    }

    /// B-74. A cascade arrives as its cause and a count of what carries it, and prints as
    /// one line under the failure — twenty nodes saying "an input is in error" name no fix
    /// the file above them does not. `ErrorReport.lines` is the twin of this on the engine's
    /// side, and prints the same line.
    func test_errorsPrintsTheCascadeUnderACauseAsOneLine() throws {
        connection.reply(.errors(records: [
            ErrorRecord(label: "StaticFile #12 'input:/shared.h'",
                        entries: [ErrorEntry(ports: ["output"], message: "the file is gone")],
                        downstreamCarrierCount: 20),
        ]))

        try run("errors")

        XCTAssertEqual(context.messages, [
            "1 error across 1 node:\n",
            "❌ StaticFile #12 'input:/shared.h'",
            "   · the file is gone",
            "   · and 20 nodes downstream carry it",
            "",
        ])
    }

    func test_oneNodeDownstreamPrintsAsOne() throws {
        connection.reply(.errors(records: [
            ErrorRecord(label: "StaticFile #12 'input:/shared.h'",
                        entries: [ErrorEntry(ports: ["output"], message: "the file is gone")],
                        downstreamCarrierCount: 1),
        ]))

        try run("errors")

        XCTAssertEqual(context.messages.last(where: { $0.contains("·") }),
                       "   · and 1 node downstream carries it")
    }

    func test_waitSendsWaitAndReportsSettled() throws {
        try run("wait")

        XCTAssertEqual(connection.daemonRequests, [.wait])
        XCTAssertEqual(context.messages, ["Settled."])
    }

    /// The settle-time event this unblocks can fire and count *during* the `.wait`
    /// request, so the guard must already be clear before that request goes out, not
    /// after it comes back.
    func test_waitResetsErrorAccountingBeforeSendingTheRequest() throws {
        let orderLog = OrderLog()
        connection.orderLog = orderLog
        context.orderLog    = orderLog

        try run("wait")

        XCTAssertEqual(orderLog.entries, ["resetErrorRecordAccounting", "send"])
    }

    /// A wait with a batch open would block for good: the batch holds the very signal the
    /// wait is waiting on (B-61). Refused, naming the command that ends the batch.
    func test_waitWithABatchOpenIsRefusedAndSendsNothing() throws {
        context.openBatchDepth = 1

        try run("wait")

        XCTAssertEqual(connection.daemonRequests, [])
        XCTAssertEqual(context.errors, ["wait: a batch is open; `commit` ends it and waits"])
        XCTAssertEqual(context.resetErrorRecordAccountingCallCount, 0)
    }

    // MARK: - check

    func test_checkWithNoFindingsSaysSo() throws {
        connection.reply(.check(scheduledNodes: 0), body: try MessageCoder.encode([CheckFinding]()))

        try run("check")

        XCTAssertEqual(connection.daemonRequests, [.check])
        XCTAssertEqual(context.messages, ["✅ no findings"])
        XCTAssertEqual(context.errors, [], "a clean graph is not an error")
    }

    /// One line per finding, and each counted — a scripted run over a graph that broke an
    /// invariant has to exit non-zero, the way one that reported an error does.
    func test_checkPrintsALinePerFindingAndCountsEachAsAnError() throws {
        let findings = [
            CheckFinding(kind: .productWithNoProducer, subject: "OutputFile #12 'output:/app'",
                         sentence: "nothing is wired to its required input port 'input', so it can never be produced"),
            CheckFinding(kind: .errorWithoutMessage, subject: "ClangLinker #40",
                         sentence: "its port 'output' is in error with no message, so nothing says what failed"),
        ]
        connection.reply(.check(scheduledNodes: 0), body: try MessageCoder.encode(findings))

        try run("check")

        XCTAssertEqual(context.errors, [
            "❌ OutputFile #12 'output:/app': nothing is wired to its required input port 'input', "
          + "so it can never be produced",
            "❌ ClangLinker #40: its port 'output' is in error with no message, so nothing says what failed",
        ])
        XCTAssertEqual(context.messages, [], "a settled graph needs no caveat")
    }

    /// A graph the engine is still working on is one where a node it has not finished
    /// wiring looks exactly like a node whose wiring is missing. Said before the findings,
    /// because it is how they are to be read — and said rather than acted on: a graph that
    /// is stuck is a graph whose nodes stay scheduled, and that is the case `check` exists
    /// for.
    func test_checkSaysWhenNodesWereStillScheduled() throws {
        let finding = CheckFinding(kind: .productWithNoProducer, subject: "OutputFile #12 'output:/app'",
                                   sentence: "nothing is wired to its required input port 'input'")
        connection.reply(.check(scheduledNodes: 3), body: try MessageCoder.encode([finding]))

        try run("check")

        XCTAssertEqual(context.messages, [
            "3 nodes were still scheduled; a finding about wiring may be work in flight — run `wait` first.",
        ])
        XCTAssertEqual(context.errors.count, 1, "the caveat does not replace the findings")
    }

    func test_checkSaysOneScheduledNodeInTheSingular() throws {
        connection.reply(.check(scheduledNodes: 1), body: try MessageCoder.encode([CheckFinding]()))

        try run("check")

        XCTAssertEqual(context.messages, [
            "1 node was still scheduled; a finding about wiring may be work in flight — run `wait` first.",
            "✅ no findings",
        ])
    }

    /// A reply with no body at all is a peer that sent none, which reads as the empty list
    /// it is rather than as a decode failure standing in for a report.
    func test_checkWithNoBodyReadsAsNoFindings() throws {
        connection.reply(.check(scheduledNodes: 0))

        try run("check")

        XCTAssertEqual(context.messages, ["✅ no findings"])
    }

    // MARK: - reset

    func test_resetKeepsTheCacheAndAnnouncesTheRebuild() throws {
        connection.reply(.reset(archivedGraphPath: nil))

        try run("reset")

        XCTAssertEqual(connection.daemonRequests, [.reset(clearCache: false)])
        XCTAssertEqual(context.messages, ["Rebuild started.", Self.checkOffer])
    }

    /// The cache is what makes a reset cheap, so discarding it is asked for by name.
    func test_resetWithTheCacheFlagAsksForTheCacheToGoToo() throws {
        connection.reply(.reset(archivedGraphPath: nil))

        try run("reset", ["--cache"])

        XCTAssertEqual(connection.daemonRequests, [.reset(clearCache: true)])
        XCTAssertEqual(context.messages, ["Cache discarded. Rebuild started.", Self.checkOffer])
    }

    /// The graph a reset discards is copied aside, and the only way to find that copy is
    /// for the reply to name it.
    func test_resetPrintsWhereTheDiscardedGraphWent() throws {
        connection.reply(.reset(archivedGraphPath: "/semel-home/graph.sqlite.broken-2026-09-23T101500Z"))

        try run("reset")

        XCTAssertEqual(context.messages, [
            "Graph copied to /semel-home/graph.sqlite.broken-2026-09-23T101500Z — yours to delete.",
            "Rebuild started.",
            Self.checkOffer,
        ])
    }

    /// A misspelled flag is a request the user did not mean, not a plain reset — and what
    /// the user reads is `"\(error)"`, which reaches `description` and not
    /// `errorDescription`.
    func test_resetRejectsAnOptionItDoesNotKnow() throws {
        XCTAssertThrowsError(try run("reset", ["--caches"])) { error in
            XCTAssertEqual("\(error)", "reset: unknown option '--caches'")
        }

        XCTAssertEqual(connection.daemonRequests, [])
    }

    func test_debugPrintsTheTextItGetsBack() throws {
        connection.reply(.debug, body: Data("BUILD GRAPH STATE (0 nodes)".utf8))

        try run("debug")

        XCTAssertEqual(connection.daemonRequests, [.debug(cacheKey: nil)])
        XCTAssertEqual(context.messages, ["BUILD GRAPH STATE (0 nodes)"])
    }

    /// B-13. A key given to `debug` asks about that cache entry rather than the graph, and
    /// the same body carries the answer.
    func test_debugWithAKeyAsksAboutThatCacheEntry() throws {
        connection.reply(.debug, body: Data("cache entry abc\nnode SampleTool@1".utf8))

        try run("debug", ["abc"])

        XCTAssertEqual(connection.daemonRequests, [.debug(cacheKey: "abc")])
        XCTAssertEqual(context.messages, ["cache entry abc\nnode SampleTool@1"])
    }

    func test_debugWithMoreThanOneArgumentSaysWhatItTakes() throws {
        try run("debug", ["abc", "def"])

        XCTAssertEqual(connection.daemonRequests, [])
        XCTAssertEqual(context.errors, ["debug: takes at most one argument, the key of a cache entry"])
    }

    func test_toolsRendersEachNamespaceAsConfigText() throws {
        connection.reply(.tools(namespaces: [
            ToolNamespaceRecord(namespace: "c.compiler", toolName: "clang", descriptors: []),
            ToolNamespaceRecord(namespace: "swift.compiler", toolName: "swiftc", descriptors: [
                ToolDescriptorRecord(name: "swiftc", version: "6.0", platform: "macOS", architecture: "arm64",
                                     machineSettings: ["sdk": "/x"]),
            ]),
        ]))

        try run("tools")

        XCTAssertEqual(context.messages, ["""
            // c.compiler: no clang is installed on this machine

            swift.compiler.toolDescriptor.name=swiftc
            swift.compiler.toolDescriptor.version=6.0
            swift.compiler.toolDescriptor.platform=macOS
            swift.compiler.toolDescriptor.architecture=arm64
            swift.compiler.sdk=/x
            """])
    }

    func test_aServerErrorIsThrownForTheInterpreterToPrint() {
        connection.responses.append((.error(.nodeError(description: "wire missing")), nil))

        XCTAssertThrowsError(try run("nudge")) { error in
            XCTAssertEqual((error as? ServerError)?.description, "wire missing")
        }
    }

    /// B-94. A reply the server cannot frame reached the prompt as a closed socket and
    /// "error 2". The user is told which command was refused, how large its answer was and
    /// what the limit is.
    func test_aRefusedReplySaysWhatWasTooLargeAndHowLarge() {
        connection.responses.append((.error(.replyTooLarge(request: "debug", bytes: 3_000_000, limit: 1_048_576)), nil))

        XCTAssertThrowsError(try run("debug")) { error in
            let message = (error as? ServerError)?.description ?? "\(error)"
            XCTAssertTrue(message.contains("`debug`"),   message)
            XCTAssertTrue(message.contains("3000000"),   message)
            XCTAssertTrue(message.contains("1048576"),   message)
        }
    }
}
