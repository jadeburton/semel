//
//  PushStatusTests.swift
//  SemelCLITests
//
//  B-167. The line a push redraws in place while it reads, sends and commits: what each
//  phase says, the order a push goes through them, that the line is gone before the push's
//  own lines, and how the indicator draws it — at once on a new phase, held back within
//  one, around anything printed, and never into a pipe.
//

@testable import SemelCLI
import SemelNodeKit
import SemelProtocol
import XCTest

final class PushStatusRenderingTests: XCTestCase {

    /// Each phase says what it is doing and the counts the client has, grouped as the
    /// progress line groups them.
    func test_eachPhaseSaysWhatItIsDoingWithItsCounts() {
        XCTAssertEqual(PushStatus.reading(read: 0, total: nil).line, "Reading files…")
        XCTAssertEqual(PushStatus.reading(read: 12_480, total: 20_730).line, "Reading 12,480 of 20,730 files…")
        XCTAssertEqual(PushStatus.comparing.line, "Comparing with what the server holds…")
        XCTAssertEqual(PushStatus.pushing(recorded: 8_192, total: 20_730, bytesSent: 312 * ByteCount.mebibyte).line,
                       "Pushing 8,192 of 20,730 files (312.0 MB sent)…")
        XCTAssertEqual(PushStatus.committing(files: 20_730).line, "Committing 20,730 files: waiting for the server…")
    }

    /// No bytes are claimed where none were sent — every file already held — and one file
    /// is a file.
    func test_nothingSentIsNotABytesCountAndOneFileIsSingular() {
        XCTAssertEqual(PushStatus.pushing(recorded: 0, total: 20_730, bytesSent: 0).line, "Pushing 0 of 20,730 files…")
        XCTAssertEqual(PushStatus.reading(read: 1, total: 1).line, "Reading 1 of 1 file…")
        XCTAssertEqual(PushStatus.committing(files: 1).line, "Committing 1 file: waiting for the server…")
    }

    /// The phase is what a count within it shares, and what a new one changes.
    func test_aCountMovesWithinItsPhase() {
        XCTAssertEqual(PushStatus.reading(read: 0, total: nil).phase, PushStatus.reading(read: 9, total: 10).phase)
        XCTAssertEqual(PushStatus.pushing(recorded: 1, total: 2, bytesSent: 3).phase, .pushing)
        XCTAssertNotEqual(PushStatus.pushing(recorded: 2, total: 2, bytesSent: 3).phase, PushStatus.committing(files: 2).phase)
    }
}

final class PushStatusPhaseTests: XCTestCase {

    private var connection: RecordingConnection!
    private var context: TestCommandContext!
    private var externalRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        externalRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-cli-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        connection = RecordingConnection()
        context    = TestCommandContext(connection: connection, baseDirectory: externalRoot.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: externalRoot)
        try super.tearDownWithError()
    }

    /// `count` files of `bytes` bytes each under `src`, with the replies a server holding
    /// nothing gives a push of the folder, up to the batch's end.
    private func scriptFolderPush(count: Int, bytes: Int) throws {
        for index in 0..<count {
            let url = externalRoot.appendingPathComponent("src/file\(String(format: "%03d", index)).c")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: UInt8(ascii: "a"), count: bytes).write(to: url)
        }
        connection.reply(.contentRoots, body: try MessageCoder.encode([HeldFolderRoot]()))
        connection.reply(.ok)
        connection.reply(.ok)
        var remaining = count
        while remaining > 0 {
            let inRequest = min(remaining, FilePlugin.filesPerRequest)
            connection.reply(.pushFiles(outcomes: Array(repeating: .stored(didChange: true), count: inRequest)))
            remaining -= inRequest
        }
    }

    private func run(_ verb: String, _ tokens: [String]) throws {
        try FilePlugin().handle(verb: verb, tokens: tokens, context: context)
    }

    /// The phases in the order they first appear.
    private var phases: [PushStatus.Phase] {
        context.pushStatuses.map(\.phase).reduce(into: []) { phases, phase in
            if phases.last != phase {
                phases.append(phase)
            }
        }
    }

    /// A push of a folder says something from the first moment, before anything is
    /// matched or asked, and then goes through every phase in turn: asking what the server
    /// holds, reading the disk with a count of what it has read out of what it listed,
    /// pushing with a count of what the server has answered for, and committing.
    func test_aFolderPushGoesThroughEveryPhaseFromTheFirstMoment() throws {
        try scriptFolderPush(count: 3 * FilePlugin.filesPerRequest, bytes: 1_000)
        connection.reply(.ok)

        try run("push", ["src"])

        let total = 3 * FilePlugin.filesPerRequest
        XCTAssertEqual(context.pushStatuses.first, .reading(read: 0, total: nil))
        XCTAssertEqual(phases, [.reading, .comparing, .reading, .pushing, .committing])
        XCTAssertTrue(context.pushStatuses.contains(.reading(read: 0, total: total)), "\(context.pushStatuses)")
        XCTAssertTrue(context.pushStatuses.contains(.reading(read: total, total: total)), "\(context.pushStatuses)")
        let pushing = context.pushStatuses.compactMap { status -> Int? in
            guard case .pushing(let recorded, total, _) = status else {
                return nil
            }
            return recorded
        }
        XCTAssertEqual(pushing.first, 0)
        XCTAssertEqual(pushing.last, total)
        XCTAssertEqual(pushing, pushing.sorted(), "the count only grows")
        XCTAssertTrue(pushing.contains { $0 > 0 && $0 < total }, "the count moves while the push runs: \(pushing)")
        XCTAssertTrue(context.pushStatuses.contains(.pushing(recorded: total, total: total, bytesSent: total * 1_000)))
        XCTAssertEqual(context.pushStatuses.last, .committing(files: total))
    }

    /// The line says it is committing before the batch's end goes out, since the commit is
    /// the one reply the client waits on without a count; and it is gone before the push
    /// says what it did, which B-161 holds back until the commit has answered.
    func test_theCommitIsSaidBeforeItIsAskedAndTheLineIsGoneBeforePushed() throws {
        try scriptFolderPush(count: 21, bytes: 10)
        connection.reply(.ok)

        try run("push", ["src"])

        XCTAssertEqual(Array(context.transcript.suffix(3)), ["status ended", "Pushed 21 files and 1 folder", "status ended"],
                       "erased before the line, and again, to no effect, as the push returns")
        XCTAssertEqual(context.transcript.dropLast(3).last, "status: Committing 21 files: waiting for the server…")
        XCTAssertEqual(connection.daemonRequests.last, .endBatch)
    }

    /// Inside a batch the user opened, the push's own end commits nothing, so the line
    /// never says it is committing; the count says the files are pending.
    func test_insideAnOpenBatchThereIsNoCommitToWaitFor() throws {
        context.openBatchDepth = 1
        try scriptFolderPush(count: 21, bytes: 10)
        connection.reply(.ok)

        try run("push", ["src"])

        XCTAssertFalse(phases.contains(.committing), "\(context.pushStatuses)")
        XCTAssertEqual(Array(context.transcript.suffix(3)),
                       ["status ended", "Sent 21 files and 1 folder, pending the commit", "status ended"])
    }

    /// A push the barrier refuses has its line erased before the refusal is thrown, so the
    /// report the interpreter prints with its `❌` lands on a clean line.
    func test_aRefusedPushErasesTheLineBeforeTheRefusal() throws {
        try scriptFolderPush(count: 21, bytes: 10)
        connection.responses.append((.error(.batchRejected(folder: "src", lock: "src.semel-lock", expected: .contentRoot("aaa"),
                                                           found: "bbb", paths: ["src/file000.c"], pathsNotListed: 20,
                                                           listing: .lockTreeNotHeld)), nil))

        XCTAssertThrowsError(try run("push", ["src"]))

        XCTAssertEqual(context.transcript.last, "status ended")
        XCTAssertEqual(context.messages, [])
    }

    /// A wildcard push of files reads nothing before it sends, so it goes from the first
    /// line straight to pushing.
    func test_aWildcardPushOfFilesGoesFromReadingToPushing() throws {
        for index in 0..<21 {
            let url = externalRoot.appendingPathComponent("src/file\(index).c")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("\(index)".utf8).write(to: url)
        }
        connection.reply(.ok)
        connection.reply(.pushFiles(outcomes: Array(repeating: .stored(didChange: true), count: 21)))
        connection.reply(.ok)

        try run("push", ["src/*.c"])

        XCTAssertEqual(phases, [.reading, .pushing, .committing])
        XCTAssertEqual(Array(context.transcript.suffix(3)), ["status ended", "Pushed 21 files", "status ended"])
    }
}

final class PushStatusIndicatorTests: XCTestCase {

    private final class Terminal {
        var writes: [String] = []
        var now = Date(timeIntervalSince1970: 1_000)
        func advance(by seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    private var terminal: Terminal!
    private var indicator: IndicatorLine!

    private let erase = IndicatorLine.erase

    override func setUp() {
        super.setUp()
        let terminal = Terminal()
        self.terminal = terminal
        indicator = IndicatorLine(mode: .line,
                                  write:        { text in terminal.writes.append(text) },
                                  now:          { terminal.now },
                                  terminalSize: { .fallback })
    }

    override func tearDown() {
        indicator.endStatus()
        indicator.end()
        indicator = nil
        terminal  = nil
        super.tearDown()
    }

    private func pushing(_ recorded: Int) -> PushStatus {
        .pushing(recorded: recorded, total: 100, bytesSent: 0)
    }

    /// The first status is drawn at once, in place, with no newline: the push says what it
    /// is doing from its first moment, not after a delay.
    func test_theFirstStatusIsDrawnAtOnceInPlace() {
        indicator.show(.reading(read: 0, total: nil))
        XCTAssertEqual(terminal.writes, [erase + "Reading files…"])
    }

    /// A count moving within one phase faster than the redraw interval is held back; the
    /// next one past the interval draws the latest count.
    func test_countsWithinAPhaseAreHeldBackToTheRedrawInterval() {
        indicator.show(pushing(0))
        terminal.advance(by: 0.05)
        indicator.show(pushing(64))
        XCTAssertEqual(terminal.writes.count, 1)

        terminal.advance(by: 0.1)
        indicator.show(pushing(128))
        XCTAssertEqual(terminal.writes.last, erase + pushing(128).line)
    }

    /// A new phase is drawn at once, however soon after the last drawing: the commit is
    /// said when it starts, not a redraw interval later.
    func test_aNewPhaseIsDrawnAtOnce() {
        indicator.show(pushing(100))
        indicator.show(.committing(files: 100))
        XCTAssertEqual(terminal.writes, [erase + pushing(100).line, erase + PushStatus.committing(files: 100).line])
    }

    /// A line printed while the status shows lands above it, and the status comes back.
    func test_aLinePrintedMidPushLandsAboveTheStatus() {
        indicator.show(pushing(10))
        indicator.interrupting { terminal.writes.append("❌ push: src/b.c: Permission denied\n") }

        XCTAssertEqual(terminal.writes, [erase + pushing(10).line,
                                         erase,
                                         "❌ push: src/b.c: Permission denied\n",
                                         erase + pushing(10).line])
    }

    /// Ending the status erases it, and what prints next is not followed by it.
    func test_endingTheStatusErasesItForGood() {
        indicator.show(.committing(files: 3))
        indicator.endStatus()
        indicator.interrupting { terminal.writes.append("Pushed 3 files\n") }

        XCTAssertEqual(terminal.writes, [erase + PushStatus.committing(files: 3).line, erase, "Pushed 3 files\n"])
    }

    /// In a pipe, or with `SEMEL_PROGRESS=0`, nothing of the status is ever written.
    func test_aDisabledIndicatorDrawsNoStatus() throws {
        let terminal = try XCTUnwrap(self.terminal)
        let quiet = IndicatorLine(mode: .off, write: { text in terminal.writes.append(text) })
        quiet.show(.reading(read: 0, total: nil))
        quiet.show(.committing(files: 1))
        quiet.interrupting { terminal.writes.append("Pushed 1 file\n") }
        quiet.endStatus()
        XCTAssertEqual(terminal.writes, ["Pushed 1 file\n"])
    }

    /// A settle wait takes the line: the status is erased when the wait begins and not
    /// drawn while it lasts.
    func test_aSettleWaitTakesTheLine() {
        indicator.show(pushing(1))
        indicator.begin()
        indicator.show(pushing(2))
        indicator.end()

        XCTAssertEqual(terminal.writes, [erase + pushing(1).line, erase])
    }

    /// Cut to the terminal's width, so it never wraps onto a row the next erase misses.
    func test_theStatusIsCutToTheTerminalsWidth() throws {
        let terminal = try XCTUnwrap(self.terminal)
        let narrow = IndicatorLine(mode: .line,
                                   write:        { text in terminal.writes.append(text) },
                                   now:          { terminal.now },
                                   terminalSize: { TerminalSize(columns: 20, rows: 24) })
        narrow.show(.committing(files: 20_730))
        narrow.endStatus()

        let drawn = String(terminal.writes[0].dropFirst(erase.count))
        XCTAssertTrue(drawn.hasPrefix("Committing 20,730"), drawn)
        XCTAssertTrue(drawn.hasSuffix("…"), drawn)
        XCTAssertLessThanOrEqual(TerminalText.displayWidth(drawn), 19, drawn)
    }
}
