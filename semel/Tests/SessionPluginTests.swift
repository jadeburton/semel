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

/// B-136. `base <path>` remembers the base in the Semel home and `base --forget` removes it,
/// over a home of the test's own: `SEMEL_HOME` is set for each test and put back after it,
/// so nothing here touches the real one.
final class BaseVerbTests: XCTestCase {

    private var context: TestCommandContext!
    private var home: URL!
    private var tree: URL!
    private var savedHome: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-base-verb-tests/\(UUID().uuidString)", isDirectory: true)
        home = scratch.appendingPathComponent("home", isDirectory: true)
        tree = scratch.appendingPathComponent("tree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        savedHome = ProcessInfo.processInfo.environment["SEMEL_HOME"]
        setenv("SEMEL_HOME", home.path, 1)
        context = TestCommandContext(connection: RecordingConnection(), baseDirectory: "/where/semel/started")
    }

    override func tearDown() {
        if let savedHome {
            setenv("SEMEL_HOME", savedHome, 1)
        } else {
            unsetenv("SEMEL_HOME")
        }
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
        super.tearDown()
    }

    private func run(_ tokens: [String]) throws {
        try SessionPlugin().handle(verb: "base", tokens: tokens, context: context)
    }

    private var rememberedFile: URL { home.appendingPathComponent(RememberedBase.fileName) }

    func test_theFileIsInTheSemelHome() {
        XCTAssertEqual(RememberedBase.file.path, rememberedFile.path)
    }

    func test_basePathSetsTheSessionsBaseAndRemembersIt() throws {
        try run([tree.path])

        let expanded = ExternalPathSanitizer.expandPartialPath(tree.path)
        XCTAssertEqual(context.baseDirectory, expanded)
        XCTAssertEqual(context.messages, ["Base directory set to \(expanded) and remembered"])
        XCTAssertEqual(try RememberedBase.read(from: rememberedFile)?.directory, expanded)
    }

    /// The last `base` is the one remembered: a script's `base` overrides the remembered
    /// one and remembers itself.
    func test_aLaterBaseReplacesTheRememberedOne() throws {
        let other = tree.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        try run([tree.path])
        try run([other.path])

        XCTAssertEqual(try RememberedBase.read(from: rememberedFile)?.directory,
                       ExternalPathSanitizer.expandPartialPath(other.path))
    }

    func test_baseAlonePrintsTheSessionsBaseAndWritesNothing() throws {
        try run([])

        XCTAssertEqual(context.messages, ["/where/semel/started"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: rememberedFile.path))
    }

    /// Neither the session nor the file moves to a path that is not a directory.
    func test_aPathThatIsNotADirectoryIsRefusedAndNothingIsRemembered() throws {
        let file = tree.appendingPathComponent("file.txt")
        try Data("x".utf8).write(to: file)

        try run([file.path])
        try run([tree.appendingPathComponent("missing").path])

        XCTAssertEqual(context.baseDirectory, "/where/semel/started")
        XCTAssertEqual(context.errors.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rememberedFile.path))
    }

    /// The file goes; the session's base stays where it was set, and the reply says both.
    func test_forgetRemovesTheFileAndKeepsTheSessionsBase() throws {
        try run([tree.path])
        try run(["--forget"])

        let expanded = ExternalPathSanitizer.expandPartialPath(tree.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rememberedFile.path))
        XCTAssertEqual(context.baseDirectory, expanded)
        XCTAssertEqual(context.messages.last, "Base directory no longer remembered; this session's is still \(expanded)")
        XCTAssertEqual(context.errors, [])
    }

    func test_forgetWithNothingRememberedSaysSoAndIsNoError() throws {
        try run(["--forget"])

        XCTAssertEqual(context.messages, ["No base directory was remembered; this session's is /where/semel/started"])
        XCTAssertEqual(context.errors, [])
    }
}
