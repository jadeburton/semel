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
}
