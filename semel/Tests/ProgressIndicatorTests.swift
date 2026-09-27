//
//  ProgressIndicatorTests.swift
//  SemelCLITests
//
//  B-95. The progress line: what it says, when it is drawn, and — the part a transcript
//  depends on — that it is erased before anything else prints and is never drawn at all
//  when the terminal is not one.
//

@testable import SemelCLI
import SemelProtocol
import XCTest

final class ProgressPolicyTests: XCTestCase {

    func test_shownAtATerminalUnlessTurnedOff() {
        XCTAssertTrue(ProgressPolicy.shows(environment: [:], standardOutputIsTerminal: true))
        XCTAssertFalse(ProgressPolicy.shows(environment: ["SEMEL_PROGRESS": "0"], standardOutputIsTerminal: true))
        XCTAssertTrue(ProgressPolicy.shows(environment: ["SEMEL_PROGRESS": "1"], standardOutputIsTerminal: true))
    }

    /// A pipe never sees it, whatever the environment says: the scripted run's output is
    /// the lines and nothing else.
    func test_neverShownIntoAPipe() {
        XCTAssertFalse(ProgressPolicy.shows(environment: [:], standardOutputIsTerminal: false))
        XCTAssertFalse(ProgressPolicy.shows(environment: ["SEMEL_PROGRESS": "1"], standardOutputIsTerminal: false))
    }

    func test_aDumbTerminalIsNotDrawnOn() {
        XCTAssertFalse(ProgressPolicy.shows(environment: ["TERM": "dumb"], standardOutputIsTerminal: true))
    }
}

final class ProgressLineRendererTests: XCTestCase {

    private func record(scheduled: Int = 0, computed: Int = 0, fromCache: Int = 0, pending: Int = 0,
                        running: Int = 0) -> ProgressRecord {
        ProgressRecord(scheduled: scheduled, computed: computed, fromCache: fromCache, pending: pending,
                       running: (0..<running).map { ActiveNode(type: "SampleTool", name: "input:/n\($0)") })
    }

    /// What moves first, then what is done as the summary will count it, then the clock.
    func test_theLineReadsRunningPendingDoneAndElapsed() {
        let line = ProgressLineRenderer.line(record(scheduled: 1_614, computed: 1_100, fromCache: 104, pending: 340,
                                                    running: 10),
                                             elapsed: 92)
        XCTAssertEqual(line, "⏳ 10 running, 340 pending · 1,204 done: 1,100 computed, 104 from cache · 1m 32s")
    }

    /// The last record of a settle: nothing running, nothing pending, the counts the
    /// summary is about to print.
    func test_aDrainedPassRendersItsTotals() {
        let line = ProgressLineRenderer.line(record(scheduled: 9, computed: 4, fromCache: 5), elapsed: 3)
        XCTAssertEqual(line, "⏳ 0 running, 0 pending · 9 done: 4 computed, 5 from cache · 3s")
    }

    /// What `watch` leaves behind scrolls, so it carries the counts and neither the `⏳`
    /// nor a clock.
    func test_whereTheSettleStoodIsTheCountsAlone() {
        XCTAssertEqual(ProgressLineRenderer.standing(record(scheduled: 1_614, computed: 1_100, fromCache: 104,
                                                            pending: 340, running: 10)),
                       "Still settling — 10 running, 340 pending · 1,204 done: 1,100 computed, 104 from cache.")
        XCTAssertEqual(ProgressLineRenderer.standing(nil), "No settle in progress.")
    }

    func test_thousandsAreGroupedWhateverTheLocale() {
        XCTAssertEqual(ProgressLineRenderer.grouped(0), "0")
        XCTAssertEqual(ProgressLineRenderer.grouped(999), "999")
        XCTAssertEqual(ProgressLineRenderer.grouped(1_000), "1,000")
        XCTAssertEqual(ProgressLineRenderer.grouped(1_234_567), "1,234,567")
    }

    func test_durationsGrowFromSecondsToHours() {
        XCTAssertEqual(ProgressLineRenderer.duration(0), "0s")
        XCTAssertEqual(ProgressLineRenderer.duration(45.9), "45s")
        XCTAssertEqual(ProgressLineRenderer.duration(92), "1m 32s")
        XCTAssertEqual(ProgressLineRenderer.duration(3_725), "1h 02m")
    }
}

final class IndicatorLineTests: XCTestCase {

    /// A clock the test moves, and a terminal that remembers every write as one entry.
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
        terminal  = Terminal()
        indicator = IndicatorLine(enabled: true,
                                  write: { [terminal] text in terminal!.writes.append(text) },
                                  now:   { [terminal] in terminal!.now })
    }

    override func tearDown() {
        indicator.end()
        indicator = nil
        terminal  = nil
        super.tearDown()
    }

    private func record(running: Int, pending: Int) -> ProgressRecord {
        ProgressRecord(scheduled: 0, computed: 0, fromCache: 0, pending: pending,
                       running: (0..<running).map { ActiveNode(type: "SampleTool", name: "input:/n\($0)") })
    }

    private func line(running: Int, pending: Int, elapsed: TimeInterval) -> String {
        ProgressLineRenderer.line(record(running: running, pending: pending), elapsed: elapsed)
    }

    /// Nothing before the wait, a line per event far enough apart, and an erase at the end
    /// so the command's result lands on a clean line.
    func test_drawsOnEventsDuringAWaitAndErasesAtItsEnd() {
        indicator.update(record(running: 1, pending: 1))
        XCTAssertEqual(terminal.writes, [], "no wait, no line")

        indicator.begin()
        indicator.update(record(running: 2, pending: 5))
        terminal.advance(by: 1)
        indicator.update(record(running: 2, pending: 3))
        indicator.end()

        XCTAssertEqual(terminal.writes, [erase + line(running: 2, pending: 5, elapsed: 0),
                                         erase + line(running: 2, pending: 3, elapsed: 1),
                                         erase])
    }

    /// Two events within the redraw interval are one drawing; the second is kept and the
    /// next tick shows it, with the clock moved on.
    func test_eventsCloserThanTheRedrawIntervalWaitForTheTick() {
        indicator.begin()
        indicator.update(record(running: 1, pending: 9))
        terminal.advance(by: 0.05)
        indicator.update(record(running: 1, pending: 8))
        XCTAssertEqual(terminal.writes.count, 1, "the second event is within the interval")

        terminal.advance(by: 1)
        indicator.tick()
        XCTAssertEqual(terminal.writes.last, erase + line(running: 1, pending: 8, elapsed: 1.05))
    }

    /// A line printed mid-wait — a notice, an error report — gets a clean line of its own
    /// and the indicator comes back under it.
    func test_anInterruptionErasesPrintsAndRedraws() {
        indicator.begin()
        indicator.update(record(running: 1, pending: 1))
        indicator.interrupting { terminal.writes.append("Collected 3 objects\n") }

        XCTAssertEqual(terminal.writes, [erase + line(running: 1, pending: 1, elapsed: 0),
                                         erase,
                                         "Collected 3 objects\n",
                                         erase + line(running: 1, pending: 1, elapsed: 0)])
    }

    /// Before anything was drawn there is nothing to erase, and nothing is drawn after
    /// the interruption either: a wait with no progress yet stays a wait with no line.
    func test_anInterruptionBeforeTheFirstEventJustPrints() {
        indicator.begin()
        indicator.interrupting { terminal.writes.append("Settled.\n") }
        XCTAssertEqual(terminal.writes, ["Settled.\n"])
    }

    /// Disabled — a pipe, `SEMEL_PROGRESS=0` — nothing is ever written but what the
    /// interrupting body writes itself.
    func test_aDisabledIndicatorWritesNothing() {
        let quiet = IndicatorLine(enabled: false, write: { [terminal] text in terminal!.writes.append(text) })
        quiet.begin()
        quiet.update(record(running: 3, pending: 3))
        quiet.tick()
        quiet.interrupting { terminal.writes.append("line\n") }
        quiet.end()
        XCTAssertEqual(terminal.writes, ["line\n"])
    }

    /// The tick redraws only while a wait is on and something has arrived to draw.
    func test_aTickOutsideAWaitDrawsNothing() {
        indicator.tick()
        indicator.begin()
        indicator.tick()
        indicator.end()
        XCTAssertEqual(terminal.writes, [])
    }

    /// A wait or a watch begun mid-settle draws where the settle last stood at once,
    /// rather than waiting for a node to start or finish, which under a long compile is
    /// minutes.
    func test_beginningMidSettleDrawsTheLastRecordAtOnce() {
        indicator.begin(showing: record(running: 4, pending: 12))
        XCTAssertEqual(terminal.writes, [erase + line(running: 4, pending: 12, elapsed: 0)])

        terminal.advance(by: 1)
        indicator.tick()
        XCTAssertEqual(terminal.writes.last, erase + line(running: 4, pending: 12, elapsed: 1))
    }
}

/// B-95. What the interpreter keeps from the events for `watch`: where the settle under way
/// stands, and how many have finished.
final class SettleProgressTrackingTests: XCTestCase {

    private var connection: RecordingConnection!
    private var interpreter: CommandInterpreter!

    override func setUpWithError() throws {
        try super.setUpWithError()
        connection = RecordingConnection()
        connection.responses.append((.hello(.accepted(serverVersion: "test", databasePath: "/tmp/graph")), nil))
        interpreter = CommandInterpreter(connection: connection, baseDirectory: NSTemporaryDirectory())
        interpreter.output = { _ in }
        _ = try interpreter.connect()
    }

    private func deliver(_ event: DaemonEvent) {
        connection.onEvent?(.daemon(event))
    }

    func test_aProgressEventIsWhereTheSettleStandsUntilItSettles() {
        let record = ProgressRecord(scheduled: 3, computed: 1, fromCache: 0, pending: 1,
                                    running: [ActiveNode(type: "SampleTool", name: "input:/a")])
        XCTAssertNil(interpreter.settleInProgress)
        XCTAssertEqual(interpreter.settlesFinished, 0)

        deliver(.progress(record: record))
        XCTAssertEqual(interpreter.settleInProgress, record)
        XCTAssertEqual(interpreter.settlesFinished, 0)

        deliver(.settled(scheduled: 3, computed: 3, fromCache: 0, errors: 0))
        XCTAssertNil(interpreter.settleInProgress)
        XCTAssertEqual(interpreter.settlesFinished, 1)
    }

    /// The interpreter's own `watch`, over a scripted key: the settle the events describe
    /// is the one the key reports.
    func test_theInterpretersWatchReportsTheSettleTheEventsDescribe() {
        var lines: [String] = []
        interpreter.output = { lines.append($0) }
        interpreter.keyReader = ScriptedKeyReader()
        deliver(.progress(record: ProgressRecord(scheduled: 5, computed: 2, fromCache: 1, pending: 2, running: [])))

        XCTAssertEqual(interpreter.handleCommand("watch"), .success)

        XCTAssertEqual(lines, [EnginePlugin.watchBegins,
                               "Still settling — 0 running, 2 pending · 3 done: 2 computed, 1 from cache."])
    }
}

/// B-95. The real terminal reader over a pseudo-terminal: raw for the wait, back as it was
/// afterwards, ended by a key or by the caller.
final class TerminalKeyReaderTests: XCTestCase {

    private var controller: Int32 = -1
    private var terminal: Int32 = -1

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard openpty(&controller, &terminal, nil, nil, nil) == 0 else {
            throw XCTSkip("no pseudo-terminal available: \(String(cString: strerror(errno)))")
        }
    }

    override func tearDown() {
        close(controller)
        close(terminal)
        super.tearDown()
    }

    private func localModes() -> tcflag_t {
        var settings = termios()
        tcgetattr(terminal, &settings)
        return settings.c_lflag
    }

    func test_aPipeIsNotATerminal() throws {
        let pipe = Pipe()
        XCTAssertFalse(TerminalKeyReader(fileDescriptor: pipe.fileHandleForReading.fileDescriptor).isTerminal)
        XCTAssertTrue(TerminalKeyReader(fileDescriptor: terminal).isTerminal)
    }

    /// Any key, with no Return after it, ends the wait — and the terminal is in line mode
    /// with echo again afterwards, whatever else was typed being discarded.
    func test_aKeyEndsTheWaitAndTheTerminalIsPutBack() throws {
        let before = localModes()
        XCTAssertNotEqual(before & tcflag_t(ICANON), 0, "a fresh pseudo-terminal is in line mode")
        var modesDuringTheWait: tcflag_t = 0
        var asked = 0

        let outcome = try TerminalKeyReader(fileDescriptor: terminal).waitForKey(orUntil: {
            asked += 1
            if asked == 1 {
                modesDuringTheWait = localModes()
                _ = "q and more".withCString { write(controller, $0, strlen($0)) }
            }
            return false
        })

        XCTAssertEqual(outcome, .keyPressed)
        XCTAssertEqual(modesDuringTheWait & tcflag_t(ECHO | ICANON | ISIG), 0, "raw for the wait")
        XCTAssertEqual(localModes(), before, "put back as it was")
        var descriptor = pollfd(fd: terminal, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&descriptor, 1, 0), 0, "what was typed after the key is not left for the prompt")
    }

    /// The caller's condition ends the wait with no key, and the terminal is put back.
    func test_theCallerCanEndTheWait() throws {
        let before = localModes()
        var asked = 0

        let outcome = try TerminalKeyReader(fileDescriptor: terminal).waitForKey(orUntil: {
            asked += 1
            return asked > 2
        })

        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(localModes(), before)
    }

    /// Not a terminal at all: the settings cannot be read, and that is an error naming the
    /// call rather than a wait on something no key reaches.
    func test_aDescriptorThatIsNoTerminalIsAnError() {
        let pipe = Pipe()
        XCTAssertThrowsError(try TerminalKeyReader(fileDescriptor: pipe.fileHandleForReading.fileDescriptor)
                                .waitForKey(orUntil: { false })) { error in
            XCTAssertTrue("\(error)".contains("tcgetattr"), "\(error)")
        }
    }
}
