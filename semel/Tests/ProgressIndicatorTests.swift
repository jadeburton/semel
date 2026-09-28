//
//  ProgressIndicatorTests.swift
//  SemelCLITests
//
//  B-95. The progress line and the dashboard: what they say, when they are drawn, and —
//  the part a transcript depends on — that they are erased before anything else prints and
//  are never drawn at all when the terminal is not one.
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

    /// The dashboard is a size of the one setting: `full` asks for it, `0` for nothing,
    /// and unset, `1` or anything unknown keeps the line.
    func test_theModeIsTheSettingsSize() {
        func mode(_ value: String?) -> ProgressPolicy.Mode {
            ProgressPolicy.mode(environment: value.map { ["SEMEL_PROGRESS": $0] } ?? [:], standardOutputIsTerminal: true)
        }
        XCTAssertEqual(mode(nil), .line)
        XCTAssertEqual(mode("1"), .line)
        XCTAssertEqual(mode("yes"), .line)
        XCTAssertEqual(mode("full"), .dashboard)
        XCTAssertEqual(mode("0"), .off)
    }

    /// Asking for the dashboard does not reach a pipe or a dumb terminal either.
    func test_theDashboardIsNeverDrawnWhereTheLineIsNot() {
        XCTAssertEqual(ProgressPolicy.mode(environment: ["SEMEL_PROGRESS": "full"], standardOutputIsTerminal: false), .off)
        XCTAssertEqual(ProgressPolicy.mode(environment: ["SEMEL_PROGRESS": "full", "TERM": "dumb"],
                                           standardOutputIsTerminal: true),
                       .off)
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

    /// Too wide for the terminal, the line gives up the split of what is done before it
    /// gives up the clock, and is cut only when even that does not fit.
    func test_aLineTooWideDropsTheSplitBeforeTheClock() {
        let large = record(scheduled: 1_614, computed: 1_100, fromCache: 104, pending: 340, running: 10)

        XCTAssertEqual(ProgressLineRenderer.line(large, elapsed: 92, fitting: 80),
                       "⏳ 10 running, 340 pending · 1,204 done: 1,100 computed, 104 from cache · 1m 32s")
        XCTAssertEqual(ProgressLineRenderer.line(large, elapsed: 92, fitting: 79),
                       "⏳ 10 running, 340 pending · 1,204 done · 1m 32s")
        XCTAssertEqual(ProgressLineRenderer.line(large, elapsed: 92, fitting: 20), "⏳ 10 running, 340 …")
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
        indicator = IndicatorLine(mode: .line,
                                  write:        { [terminal] text in terminal!.writes.append(text) },
                                  now:          { [terminal] in terminal!.now },
                                  terminalSize: { .fallback })
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
        let quiet = IndicatorLine(mode: .off, write: { [terminal] text in terminal!.writes.append(text) })
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

    /// A line wider than the terminal would wrap onto a second row the erase does not
    /// reach, and every redraw would leave its first row behind; it is cut to fit instead.
    func test_theLineIsCutToTheTerminalsWidth() {
        let narrow = IndicatorLine(mode: .line,
                                   write:        { [terminal] text in terminal!.writes.append(text) },
                                   now:          { [terminal] in terminal!.now },
                                   terminalSize: { TerminalSize(columns: 30, rows: 24) })
        narrow.begin(showing: record(running: 10, pending: 340))
        narrow.end()

        XCTAssertEqual(terminal.writes.count, 2)
        let drawn = String(terminal.writes[0].dropFirst(erase.count))
        XCTAssertTrue(drawn.hasPrefix("⏳ 10 running"), drawn)
        XCTAssertTrue(drawn.hasSuffix("…"), drawn)
        XCTAssertLessThanOrEqual(TerminalText.displayWidth(drawn), 29, drawn)
    }
}

final class ProgressDashboardRendererTests: XCTestCase {

    private let compiler = ActiveNode(type: "ClangCompiler", name: "input:/lua/lbaselib.c")
    private let linker   = ActiveNode(type: "Linker", name: "output:/lua")

    /// Type padded to the longest type shown, name padded to the longest name, elapsed
    /// right-aligned: one column each, whatever the lengths.
    func test_theNodesAreLaidOutInColumns() {
        let lines = ProgressDashboardRenderer.nodeLines([compiler, linker], elapsed: [4.29, 12], width: 79)

        XCTAssertEqual(lines, ["   ClangCompiler  input:/lua/lbaselib.c   4.2 s",
                               "   Linker         output:/lua            12.0 s"])
    }

    /// Too wide, a name loses its start — the end is what tells two compiles apart — and
    /// the line is exactly the width.
    func test_aNameTooWideIsCutFromTheLeft() {
        let lines = ProgressDashboardRenderer.nodeLines([compiler, linker], elapsed: [4.29, 12], width: 40)

        XCTAssertEqual(lines, ["   ClangCompiler  …ua/lbaselib.c   4.2 s",
                               "   Linker         output:/lua     12.0 s"])
        XCTAssertEqual(lines.map { TerminalText.displayWidth($0) }, [40, 40])
    }

    /// The frame is the totals line and then the nodes, in the order they started.
    func test_theFrameIsTheTotalsThenTheNodes() {
        let record = ProgressRecord(scheduled: 9, computed: 4, fromCache: 1, pending: 3, running: [compiler, linker])

        let lines = ProgressDashboardRenderer.lines(record, elapsed: 7, nodeElapsed: [4.29, 12], size: .fallback)

        XCTAssertEqual(lines, ["⏳ 2 running, 3 pending · 5 done: 4 computed, 1 from cache · 7s",
                               "   ClangCompiler  input:/lua/lbaselib.c   4.2 s",
                               "   Linker         output:/lua            12.0 s"])
    }

    /// Nothing running, the dashboard is the line alone.
    func test_nothingRunningIsTheTotalsAlone() {
        let record = ProgressRecord(scheduled: 9, computed: 4, fromCache: 5, pending: 0, running: [])

        XCTAssertEqual(ProgressDashboardRenderer.lines(record, elapsed: 3, nodeElapsed: [], size: .fallback),
                       ["⏳ 0 running, 0 pending · 9 done: 4 computed, 5 from cache · 3s"])
    }

    /// Taller than the terminal less two rows, the nodes that do not fit are counted
    /// on a line of their own, so the frame never scrolls out of the erase's reach.
    func test_moreNodesThanRowsAreCounted() {
        let running = (0..<6).map { ActiveNode(type: "SampleTool", name: "input:/n\($0)") }
        let record  = ProgressRecord(scheduled: 6, computed: 0, fromCache: 0, pending: 0, running: running)

        let lines = ProgressDashboardRenderer.lines(record, elapsed: 0, nodeElapsed: Array(repeating: 1, count: 6),
                                                    size: TerminalSize(columns: 80, rows: 7))

        XCTAssertEqual(lines.count, 5, "the rows less two")
        XCTAssertEqual(Array(lines.dropFirst()), ["   SampleTool  input:/n0  1.0 s",
                                                  "   SampleTool  input:/n1  1.0 s",
                                                  "   SampleTool  input:/n2  1.0 s",
                                                  "   and 3 more"])
    }

    func test_aNodesTimeIsTenthsUnderAMinute() {
        XCTAssertEqual(ProgressDashboardRenderer.nodeDuration(0), "0.0 s")
        XCTAssertEqual(ProgressDashboardRenderer.nodeDuration(4.29), "4.2 s")
        XCTAssertEqual(ProgressDashboardRenderer.nodeDuration(59.99), "59.9 s")
        XCTAssertEqual(ProgressDashboardRenderer.nodeDuration(92), "1m 32s")
    }

    /// The `⏳` takes two columns, and the width counts it so.
    func test_widthsAreTheTerminalsColumns() {
        XCTAssertEqual(TerminalText.displayWidth("⏳ 1"), 4)
        XCTAssertEqual(TerminalText.truncatedFromLeft("input:/lua/lbaselib.c", toWidth: 8), "…selib.c")
        XCTAssertEqual(TerminalText.truncatedFromRight("⏳ 10 running", toWidth: 6), "⏳ 10…")
        XCTAssertEqual(TerminalText.truncatedFromLeft("short", toWidth: 8), "short")
    }
}

final class ActiveNodeClockTests: XCTestCase {

    private let start   = Date(timeIntervalSince1970: 1_000)
    private let first   = ActiveNode(type: "SampleTool", name: "input:/a")
    private let second  = ActiveNode(type: "SampleTool", name: "input:/b")
    private let third   = ActiveNode(type: "Linker", name: "output:/app")

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    /// A node's clock starts at the first record it is in and runs across the records
    /// after; a node new in a later record starts then.
    func test_aNodeIsTimedFromTheFirstRecordItAppearsIn() {
        var clock = ActiveNodeClock()
        clock.observe([first, second], at: at(0))
        XCTAssertEqual(clock.elapsed(of: [first, second], at: at(3)), [3, 3])

        clock.observe([second, third], at: at(2))
        XCTAssertEqual(clock.elapsed(of: [second, third], at: at(5)), [5, 3])
    }

    /// A node that leaves the list is forgotten: back in a later record, it is a new run.
    func test_aNodeThatDisappearsDropsItsStamp() {
        var clock = ActiveNodeClock()
        clock.observe([first, second], at: at(0))
        clock.observe([second], at: at(2))
        clock.observe([first, second], at: at(6))

        XCTAssertEqual(clock.elapsed(of: [first, second], at: at(7)), [1, 7])
    }

    /// Two nodes of one type and one name — unnamed, say — are two clocks.
    func test_twinsAreTimedApart() {
        let unnamed = ActiveNode(type: "ConfigFilter", name: "")
        var clock   = ActiveNodeClock()
        clock.observe([unnamed], at: at(0))
        clock.observe([unnamed, unnamed], at: at(4))

        XCTAssertEqual(clock.elapsed(of: [unnamed, unnamed], at: at(5)), [5, 1])
    }
}

/// The dashboard on the terminal: several rows redrawn in place, each redraw one write
/// that goes up over every row the last frame drew.
final class DashboardIndicatorTests: XCTestCase {

    private final class Terminal {
        var writes: [String] = []
        var now = Date(timeIntervalSince1970: 1_000)
        func advance(by seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    private var terminal: Terminal!
    private var indicator: IndicatorLine!

    private let first  = ActiveNode(type: "SampleTool", name: "input:/a.c")
    private let second = ActiveNode(type: "SampleTool", name: "input:/b.c")

    override func setUp() {
        super.setUp()
        terminal  = Terminal()
        indicator = IndicatorLine(mode: .dashboard,
                                  write:        { [terminal] text in terminal!.writes.append(text) },
                                  now:          { [terminal] in terminal!.now },
                                  terminalSize: { .fallback })
    }

    override func tearDown() {
        indicator.end()
        indicator = nil
        terminal  = nil
        super.tearDown()
    }

    private func record(_ running: [ActiveNode], pending: Int) -> ProgressRecord {
        ProgressRecord(scheduled: 0, computed: 0, fromCache: 0, pending: pending, running: running)
    }

    private let threeRowFrame = "⏳ 2 running, 3 pending · 0 done: 0 computed, 0 from cache · 0s\n"
                              + "   SampleTool  input:/a.c  0.0 s\n"
                              + "   SampleTool  input:/b.c  0.0 s"

    /// Three rows drawn, the next frame goes back to the first of them — erase the row
    /// the cursor is on, then up and erase twice — and draws two, in the same write; the
    /// end erases those two.
    func test_aRedrawErasesEveryRowItDrewInOneWrite() {
        indicator.begin()
        indicator.update(record([first, second], pending: 3))
        terminal.advance(by: 1)
        indicator.update(record([second], pending: 2))
        indicator.end()

        XCTAssertEqual(terminal.writes, [
            "\r\u{1B}[2K" + threeRowFrame,
            "\r\u{1B}[2K\u{1B}[1A\u{1B}[2K\u{1B}[1A\u{1B}[2K"
                + "⏳ 1 running, 2 pending · 0 done: 0 computed, 0 from cache · 1s\n"
                + "   SampleTool  input:/b.c  1.0 s",
            "\r\u{1B}[2K\u{1B}[1A\u{1B}[2K",
        ])
    }

    /// A line printed with the dashboard up: every row erased first, the line printed on
    /// the clean row, and the dashboard drawn again beneath it.
    func test_anInterruptionErasesTheWholeDashboard() {
        indicator.begin()
        indicator.update(record([first, second], pending: 3))
        indicator.interrupting { terminal.writes.append("Collected 3 objects\n") }

        XCTAssertEqual(terminal.writes, ["\r\u{1B}[2K" + threeRowFrame,
                                         "\r\u{1B}[2K\u{1B}[1A\u{1B}[2K\u{1B}[1A\u{1B}[2K",
                                         "Collected 3 objects\n",
                                         "\r\u{1B}[2K" + threeRowFrame])
    }

    /// A node that started before the wait began shows the time it has really been
    /// running: the stamps are taken from every record, not only those during a wait.
    func test_aNodeStartedBeforeTheWaitKeepsItsClock() {
        let running = record([first], pending: 0)
        indicator.update(running)
        XCTAssertEqual(terminal.writes, [], "no wait, nothing drawn")

        terminal.advance(by: 5)
        indicator.begin(showing: running)

        XCTAssertEqual(terminal.writes, ["\r\u{1B}[2K⏳ 1 running, 0 pending · 0 done: 0 computed, 0 from cache · 0s\n"
                                         + "   SampleTool  input:/a.c  5.0 s"])
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
