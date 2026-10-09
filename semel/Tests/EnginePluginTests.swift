//
//  EnginePluginTests.swift
//  SemelCLITests
//
//  errors, reset, nudge, debug and tools over a scripted connection: what each sends and
//  how it renders what comes back.
//

@testable import SemelCLI
import SemelNodeKit
import SemelProtocol
import XCTest

final class EnginePluginTests: XCTestCase {

    private var connection: RecordingConnection!
    private var context: TestCommandContext!
    private var keyReader: ScriptedKeyReader!

    override func setUp() {
        super.setUp()
        connection = RecordingConnection()
        context    = TestCommandContext(connection: connection)
        keyReader  = ScriptedKeyReader()
        context.keyReader = keyReader
    }

    private func run(_ verb: String, _ tokens: [String] = []) throws {
        try EnginePlugin().handle(verb: verb, tokens: tokens, context: context)
    }

    /// The sentence every reset ends with: the repair points at the command that says what
    /// was wrong before the next one destroys the evidence.
    private static let checkOffer =
        "Run `check` before the next reset: it names the invariants a graph is breaking — "
      + "the evidence a reset discards."

    // MARK: - explain (B-91)

    private static let explained = Explanation(
        nodes: [ExplainedNode(label: "OutputFile #9 'output:/hello/hello'", outcome: .fromCache, isNew: false,
                              causes: [ExplainedCause(port: "input", wire: "hello", change: .unchanged,
                                                      sourceLabel: "ClangLinker #8", source: nil)],
                              unlistedCauses: 0)],
        omittedNodes: 0, nodeLimit: 40, depthLimit: 16)

    /// The file system named in the path, as a person copies it from an artifact line.
    func test_explainSendsANamedPathFromItsRoot() throws {
        connection.reply(.explain(explanation: Self.explained))

        try run("explain", ["output:/hello/hello"])

        XCTAssertEqual(connection.daemonRequests, [.explain(fileSystem: .output, path: "hello/hello")])
        XCTAssertEqual(context.messages, ["OutputFile #9 'output:/hello/hello' — from cache: 1 input unchanged"])
    }

    /// Relative to where the session stands, `..` resolved before it leaves the client.
    func test_explainResolvesARelativePathInTheCurrentFileSystem() throws {
        context.currentFileSystem    = .output
        context.currentDirectoryPath = Path("hello/sub")
        connection.reply(.explain(explanation: Self.explained))

        try run("why", ["../hello"])

        XCTAssertEqual(connection.daemonRequests, [.explain(fileSystem: .output, path: "hello/hello")])
    }

    func test_explainTakesTheOutputFlagAsCpDoes() throws {
        context.currentDirectoryPath = Path("elsewhere")
        connection.reply(.explain(explanation: Self.explained))

        try run("explain", ["-o", "hello/hello"])

        XCTAssertEqual(connection.daemonRequests, [.explain(fileSystem: .output, path: "hello/hello")])
    }

    /// No record is not "not touched": the server settled nothing since it started.
    func test_explainWithNoRecordSaysARestartForgetsIt() throws {
        connection.reply(.explain(explanation: nil))

        try run("explain", ["output:/hello/hello"])

        XCTAssertEqual(context.messages, [ExplanationRenderer.noRecord])
        XCTAssertTrue(ExplanationRenderer.noRecord.contains("restart"))
    }

    func test_explainOfAPathNotInTheGraphIsAnErrorNamingIt() throws {
        connection.responses.append((.error(.pathNotFound(path: "output:/hello/nope")), nil))

        try run("explain", ["output:/hello/nope"])

        XCTAssertEqual(context.errors, ["explain: output:/hello/nope: no such file or directory"])
    }

    func test_explainWithoutAPathSaysWhatItTakes() {
        XCTAssertThrowsError(try run("explain")) { error in
            XCTAssertEqual("\(error)", "\(CommandParserError.missingArgument(command: "explain", expected: "path"))")
        }
        XCTAssertEqual(connection.daemonRequests, [])
    }

    // MARK: - collect (B-14)

    func test_collectSaysWhatWentAndWhatStayed() throws {
        connection.reply(.collected(removed: 3, removedBytes: 1_572_864, kept: 120))

        try run("collect")

        XCTAssertEqual(connection.daemonRequests, [.collect])
        XCTAssertEqual(context.messages, ["Collected 3 unreferenced objects (1.5 MB); 120 kept."])
    }

    func test_collectWithNothingToRemoveSaysSo() throws {
        connection.reply(.collected(removed: 0, removedBytes: 0, kept: 1))

        try run("collect")

        XCTAssertEqual(context.messages, ["Nothing to collect; 1 object kept."])
    }

    func test_errorsWithNoneSaysSo() throws {
        connection.reply(.errors(records: []))

        try run("errors")

        XCTAssertEqual(connection.daemonRequests, [.errors(product: nil)])
        XCTAssertEqual(context.messages, ["No errors."])
    }

    /// A record's facts: the node behind it, for `--verbose`.
    private static func facts(_ type: String, _ id: Int64, ports: [String] = ["output"], carried: Int = 0) -> ErrorFacts {
        ErrorFacts(nodeType: type, nodeIDs: [id], ports: ports, carrierCount: carried)
    }

    /// Each cause as its block under its heading — the diagnostic and what it belongs to —
    /// and the summary under them. The count goes through `countErrorRecords`, not `outputError`, so
    /// the settle report the idle-time event already counted is not counted twice.
    func test_errorsRendersEachCauseAndTheSummary() throws {
        let record = ErrorRecord(document: .tool(text: "input:/a.c:1:1: error: boom", tool: "clang", status: 1,
                                                 subject: .source(path: "input:/a.c")),
                                 products: [], facts: Self.facts("ClangCompiler", 12, ports: ["errorLog", "output"]))
        connection.reply(.errors(records: [record]))

        try run("errors")

        XCTAssertEqual(context.messages, [
            "no product:",
            "a.c:1:1: error: boom",
            "  source: a.c",
            "",
            "1 error · every product has a value",
        ])
        XCTAssertEqual(context.countedErrorRecords, [[record]])
    }

    /// A tool's text that spans lines keeps them, indented under the first: the quoted
    /// source and the caret line are where they were relative to each other.
    func test_errorsPrintsAMultiLineDiagnosticIndentedUnderItsFirstLine() throws {
        connection.reply(.errors(records: [
            ErrorRecord(document: .tool(text: """
                            input:/hello/src/hello.c:12:9: error: incompatible pointer to integer conversion
                               12 |     int count = "one";
                                  |         ^
                            1 error generated.
                            """, tool: "clang", status: 1, subject: .source(path: "input:/hello/src/hello.c")),
                        products: [StoppedProduct(path: "output:/hello/hello")], facts: Self.facts("ClangCompiler", 24)),
        ]))

        try run("errors")

        XCTAssertEqual(context.messages, [
            "hello:",
            "hello/src/hello.c:12:9: error: incompatible pointer to integer conversion",
            "     12 |     int count = \"one\";",
            "        |         ^",
            "  1 error generated.",
            "  source: hello/src/hello.c",
            "",
            "1 error · 1 product without a value",
        ])
    }

    /// B-74. What carries a failure downstream is not an error of its own and is never
    /// listed; `--verbose` says how many nodes carry it, with the node's other facts.
    func test_errorsVerboseAddsTheEnginesFactsAndNeverListsCarriers() throws {
        let record = ErrorRecord(document: .engine(.notPushed(path: "input:/shared.h", isFolder: false), subject: nil),
                                 products: [], facts: Self.facts("StaticFile", 12, carried: 20))
        connection.reply(.errors(records: [record]))
        connection.reply(.errors(records: [record]))

        try run("errors")
        try run("errors", ["--verbose"])

        XCTAssertEqual(context.messages, [
            "no product:",
            "shared.h has not been pushed",
            "",
            "1 error · every product has a value",
            "no product:",
            "shared.h has not been pushed",
            "  node: StaticFile #12",
            "  ports: output",
            "  carried by: 20 nodes",
            "",
            "1 error · every product has a value",
        ])
        XCTAssertEqual(connection.daemonRequests, [.errors(product: nil), .errors(product: nil)])
    }

    // MARK: - errors, and what needs each cause (B-142)

    private static let compile = ErrorRecord(
        document: .tool(text: "input:/Packages/Models/A.swift:3:5: error: cannot find 'x' in scope", tool: "swiftc", status: 1,
                        subject: .target(name: "Models")),
        products: [StoppedProduct(path: "output:/Packages/libApp.a"), StoppedProduct(path: "output:/Packages/libModels.a")],
        facts: facts("SwiftCompiler", 20, ports: ["object", "swiftmodule"], carried: 40))
    private static let catalog = ErrorRecord(
        document: .tool(text: "input:/App/Res/Assets.xcassets: error: actool failed", tool: "actool", status: 1,
                        subject: .resource(path: "input:/App/Res/Assets.xcassets")),
        products: [StoppedProduct(path: "output:/App/Res/Assets.car", treeFolder: "output:/App/Res"),
                   StoppedProduct(path: "output:/App/Res/AppIcon.png", treeFolder: "output:/App/Res")],
        facts: facts("AssetCatalogCompiler", 31))
    private static let unread = ErrorRecord(
        document: .engine(.removed(path: "input:/notes.txt", isFolder: false), subject: nil),
        products: [], facts: facts("StaticFile", 3))

    /// A heading per set of products with the same errors, in path order: a tree product by
    /// its folder, once for all its entries; and a cause no product reaches last, under
    /// `no product:`.
    func test_errorsLeadsWithTheProductsAndEndsWithWhatNoProductNeeds() throws {
        connection.reply(.errors(records: [Self.unread, Self.compile, Self.catalog]))

        try run("errors")

        XCTAssertEqual(context.messages, [
            "Res:",
            "App/Res/Assets.xcassets: error: actool failed",
            "  resource: Assets.xcassets",
            "",
            "libApp.a, libModels.a:",
            "Packages/Models/A.swift:3:5: error: cannot find 'x' in scope",
            "  target: Models",
            "",
            "no product:",
            "notes.txt has been removed",
            "",
            "3 errors · 3 products without a value",
        ])
    }

    /// The idle-time report after a settle is drawn by the same renderer, with the same
    /// summary.
    func test_theIdleTimeReportIsTheSameReport() {
        XCTAssertEqual(ErrorReportRenderer.lines(for: [Self.unread, Self.compile], style: ErrorReportStyle()).last,
                       "2 errors · 2 products without a value")
    }

    /// The product as `cp` reads a path: with its file system, here from its root. The view
    /// is its heading and the errors it has no value because of, alone.
    func test_errorsForAProductIsTheProductView() throws {
        connection.reply(.errors(records: [Self.compile]))

        try run("errors", ["output:/Packages/libModels.a"])

        XCTAssertEqual(connection.daemonRequests, [.errors(product: "Packages/libModels.a")])
        XCTAssertEqual(context.messages, [
            "libModels.a:",
            "Packages/Models/A.swift:3:5: error: cannot find 'x' in scope",
            "  target: Models",
            "",
            "1 error · 2 products without a value",
        ])
        XCTAssertEqual(context.countedErrorRecords, [[Self.compile]])
    }

    /// Relative to the session's current directory, and a tree product's folder is named in
    /// the heading as a tree is in every heading: by its folder.
    func test_errorsForATreeProductsFolderReadsRelativeToTheCurrentDirectory() throws {
        context.currentFileSystem    = .output
        context.currentDirectoryPath = Path("App/sub")
        connection.reply(.errors(records: [Self.catalog]))

        try run("errors", ["../Res"])

        XCTAssertEqual(connection.daemonRequests, [.errors(product: "App/Res")])
        XCTAssertEqual(context.messages.first, "Res:")
    }

    /// A product nothing is wrong with has a value, and says so; it is not an error.
    func test_errorsForAProductWithNoErrorsSaysItHasAValue() throws {
        connection.reply(.errors(records: []))

        try run("errors", ["-o", "Packages/libModels.a"])

        XCTAssertEqual(context.messages, ["libModels.a has a value."])
        XCTAssertEqual(context.errors, [])
    }

    /// A path that is no product is an error naming it: from the server for a path in the
    /// output file system, from the client for one in the input file system, where no
    /// product is ever published.
    func test_errorsForAPathThatIsNoProductIsAnErrorNamingIt() throws {
        connection.responses.append((.error(.notAProduct(path: "output:/Packages")), nil))

        try run("errors", ["output:/Packages"])
        try run("errors", ["input:/Packages/Models/A.swift"])

        XCTAssertEqual(connection.daemonRequests, [.errors(product: "Packages")])
        XCTAssertEqual(context.errors, [
            "errors: output:/Packages: no product is published there; name a product under output:, "
          + "or a tree product's folder",
            "errors: input:/Packages/Models/A.swift: no product is published there; name a product under "
          + "output:, or a tree product's folder",
        ])
    }

    func test_waitSendsWaitAndReportsSettled() throws {
        try run("wait")

        XCTAssertEqual(connection.daemonRequests, [.wait])
        XCTAssertEqual(context.messages, ["Settled."])
    }

    /// The settle-time event this unblocks can fire and count *during* the `.wait`
    /// request, so the guard must already be clear before that request goes out, not
    /// after it comes back. The progress line lives exactly as long as the request (B-95):
    /// begun after the reset, ended before `Settled.` prints, so the result lands on a
    /// clean line rather than stepping around the indicator.
    func test_waitResetsErrorAccountingBeforeSendingTheRequest() throws {
        let orderLog = OrderLog()
        connection.orderLog = orderLog
        context.orderLog    = orderLog

        try run("wait")

        XCTAssertEqual(orderLog.entries, ["resetErrorRecordAccounting", "settleWaitBegan", "send", "settleWaitEnded"])
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

    // MARK: - watch (B-95)

    private static let midSettle = ProgressRecord(scheduled: 40, computed: 18, fromCache: 2, pending: 17,
                                                  running: [ActiveNode(type: "ClangCompiler", name: "input:/a.c")])

    /// The progress line lives exactly as long as the key wait: begun after the error
    /// accounting is reset, as a wait's is, and ended before the last word prints. A key
    /// asks nothing of the server.
    func test_watchBracketsTheKeyWaitWithTheProgressLine() throws {
        let orderLog = OrderLog()
        connection.orderLog = orderLog
        context.orderLog    = orderLog
        keyReader.orderLog  = orderLog

        try run("watch")

        XCTAssertEqual(orderLog.entries, ["resetErrorRecordAccounting", "settleWaitBegan", "waitForKey",
                                          "settleWaitEnded"])
        XCTAssertEqual(connection.daemonRequests, [])
    }

    /// At an idle engine there is nothing to draw; the key returns, saying so.
    func test_aKeyWhileIdleSaysNothingWasSettling() throws {
        try run("watch")

        XCTAssertEqual(context.messages, [EnginePlugin.watchBegins, "No settle in progress."])
        XCTAssertEqual(context.errors, [])
    }

    /// A key mid-settle leaves the settle running and says where it stood — without the
    /// `⏳`, which must never scroll, and without the watch's clock.
    func test_aKeyMidSettleSaysWhereTheSettleStood() throws {
        context.settleInProgress = Self.midSettle

        try run("watch")

        XCTAssertEqual(context.messages.last,
                       "Still settling — 1 running, 17 pending · 20 done: 18 computed, 2 from cache.")
        XCTAssertFalse(context.messages.joined().contains(Mark.working))
    }

    /// A settle finishing ends the watch as it would end a wait: one `wait` asked after it,
    /// whose reply comes after the settle's artifact lines, and then `Settled.` under them.
    func test_aSettleFinishingEndsTheWatch() throws {
        let orderLog = OrderLog()
        connection.orderLog = orderLog
        context.orderLog    = orderLog
        keyReader.orderLog  = orderLog
        context.settleInProgress = Self.midSettle
        // What the connection's thread does when the `settled` event arrives.
        let watchedContext: TestCommandContext = context
        keyReader.script = { stop in
            XCTAssertFalse(stop(), "nothing has finished yet")
            watchedContext.settleInProgress = nil
            watchedContext.settlesFinished += 1
            return stop() ? .stopped : .keyPressed
        }

        try run("watch")

        XCTAssertEqual(orderLog.entries, ["resetErrorRecordAccounting", "settleWaitBegan", "waitForKey", "send",
                                          "settleWaitEnded"])
        XCTAssertEqual(connection.daemonRequests, [.wait])
        XCTAssertEqual(context.messages, [EnginePlugin.watchBegins, "Settled."])
    }

    /// A script has no key to press: the watch says so and returns rather than hanging,
    /// and never touches the terminal or draws.
    func test_watchWithoutATerminalSaysSoAndReturns() throws {
        let orderLog = OrderLog()
        context.orderLog     = orderLog
        keyReader.isTerminal = false

        try run("watch")

        XCTAssertEqual(context.errors, ["watch: standard input is not a terminal, so no key can end it; "
                                      + "`wait` blocks until the settle ends"])
        XCTAssertEqual(keyReader.waits, 0)
        XCTAssertEqual(orderLog.entries, [])
        XCTAssertEqual(connection.daemonRequests, [])
    }

    /// A terminal that cannot be put into raw mode is reported as the command's failure,
    /// and the line is still taken down: a failure is no reason to leave it drawn.
    func test_aKeyReaderFailureStillEndsTheLine() {
        let orderLog = OrderLog()
        context.orderLog   = orderLog
        keyReader.orderLog = orderLog
        keyReader.script   = { _ in throw KeyReaderError.terminalCall(name: "tcsetattr", errorNumber: EIO) }

        XCTAssertThrowsError(try run("watch"))

        XCTAssertEqual(orderLog.entries.suffix(2), ["waitForKey", "settleWaitEnded"])
        XCTAssertEqual(context.messages, [EnginePlugin.watchBegins])
    }

    /// With a batch open the settle is held back until `commit`, and the wait a finished
    /// settle asks for would be held with it (B-61).
    func test_watchWithABatchOpenIsRefused() throws {
        context.openBatchDepth = 1

        try run("watch")

        XCTAssertEqual(context.errors, ["watch: a batch is open; `commit` ends it and waits"])
        XCTAssertEqual(keyReader.waits, 0)
    }

    /// An argument makes it the other `watch`, which starts a watcher rather than drawing
    /// the line (B-126) — here of a folder that is not there, which it says.
    func test_watchWithAnArgumentDrawsNoLine() throws {
        try run("watch", ["no-such-folder"])

        XCTAssertEqual(context.errors.count, 1)
        XCTAssertEqual(keyReader.waits, 0)
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

    // MARK: - tools (B-119)

    /// `tools` reports what the server's plugins found and writes nothing: the machine file
    /// is written outside Semel, by each toolchain's own tool, and `--write` says which.
    func test_toolsWriteNamesTheToolsThatWriteTheMachineFile() throws {
        try run("tools", ["--write", "semel.machine.config"])

        XCTAssertEqual(connection.daemonRequests, [])
        XCTAssertEqual(context.errors.count, 1)
        XCTAssertTrue(context.errors[0].contains("semel-clang <folder>"), context.errors[0])
        XCTAssertTrue(context.errors[0].contains("semel-swift prepare <folder>"), context.errors[0])
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
