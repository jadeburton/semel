// ProgressIndicator.swift
// semel
//
// One line that moves while this client waits for a settle (B-95): how far the settle
// has got, redrawn in place, erased before the command that waited prints its result.
//
// Drawn only while a command of this client is blocked — `wait`, `build`, the `commit`
// that ends a batch, and `watch`, which blocks on a key instead — and never at an idle
// prompt. The prompt is `readLine()` with no
// line editor, so a line redrawn under someone typing would erase what they typed or
// need the client to own its input line; while a command holds the thread nobody is
// typing, and those are the silent minutes B-95 is about. Nothing here is drawn when
// standard output is not a terminal, so a script, a test and the harness see the output
// they saw before.

import Foundation
import SemelProtocol

/// Whether the line is drawn at all, decided once per process from the terminal.
public enum ProgressPolicy {

    /// `SEMEL_PROGRESS=0` turns the line off at a terminal, for the person who wants a
    /// transcript without it. Beside `SEMEL_JOBS`, the second setting read from the
    /// environment; not a per-command flag, because the people who see the line are
    /// people at a terminal, and an option nobody knows about is an option nobody uses.
    public static let variable = "SEMEL_PROGRESS"

    static func shows(environment: [String: String], standardOutputIsTerminal: Bool) -> Bool {
        guard standardOutputIsTerminal else {
            return false
        }
        guard environment["TERM"] != "dumb" else {
            return false
        }
        return environment[variable] != "0"
    }

    /// The decision for this process: a terminal on standard output, not `dumb`, not
    /// turned off.
    public static func showsInThisProcess() -> Bool {
        shows(environment: ProcessInfo.processInfo.environment,
              standardOutputIsTerminal: isatty(STDOUT_FILENO) == 1)
    }
}

enum ProgressLineRenderer {

    /// The one line: what moves first, then what is done as the summary will count it,
    /// then how long this wait has been going.
    ///
    /// `done` is the tally's `computed + fromCache`, with the split beside it, so that
    /// when the settle summary replaces the line its numbers are the ones just seen. No
    /// estimate of what remains: the cascade generates work as it goes, so there is no
    /// denominator, and a bar that reaches 90% and then grows is worse than a count.
    static func line(_ record: ProgressRecord, elapsed: TimeInterval) -> String {
        "\(Mark.working) \(counts(record)) · \(duration(elapsed))"
    }

    /// The counts the line and `watch`'s last word share: running, pending, done.
    static func counts(_ record: ProgressRecord) -> String {
        let done = record.computed + record.fromCache
        return "\(grouped(record.running.count)) running, \(grouped(record.pending)) pending · "
             + "\(grouped(done)) done: \(grouped(record.computed)) computed, \(grouped(record.fromCache)) from cache"
    }

    /// What `watch` leaves on the screen when a key ends it: where the settle stood, or
    /// that none was running. No mark and no clock: it scrolls, which the `⏳` must never
    /// do, and the clock was the watch's rather than the settle's.
    static func standing(_ record: ProgressRecord?) -> String {
        guard let record else {
            return "No settle in progress."
        }
        return "Still settling — \(counts(record))."
    }

    /// Thousands separated by commas, whatever the locale: the line is compared against
    /// the summary under it, not read aloud.
    static func grouped(_ value: Int) -> String {
        let digits = Array(String(value))
        var result: [Character] = []
        for (index, digit) in digits.enumerated() {
            let fromEnd = digits.count - index
            if index > 0, fromEnd % 3 == 0 {
                result.append(",")
            }
            result.append(digit)
        }
        return String(result)
    }

    /// `45s`, `1m 32s`, `1h 02m`: as much as the reader needs to tell a minute from an
    /// hour, and no fractions, which would move faster than the counts.
    static func duration(_ elapsed: TimeInterval) -> String {
        let total   = max(0, Int(elapsed))
        let hours   = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%dh %02dm", hours, minutes)
        }
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}

/// The line on the terminal: owned by the interpreter, told when a wait begins and ends,
/// fed each progress event, and asked to step aside for anything else the client prints.
///
/// Three threads meet here — the command thread in `begin` and `end`, the connection's
/// event thread in `update` and `interrupting`, and the timer's queue in `tick` — so every
/// entry point takes the one lock, and the write to the terminal happens under it, which
/// is what keeps an erase and the line that follows it together.
final class IndicatorLine {

    /// Carriage return and erase to the end of the line: back to the start, wipe, and the
    /// next write lands on a clean line without scrolling.
    static let erase = "\r\u{1B}[2K"

    /// The least time between two redraws on events: a few thousand events over a build
    /// are not a few thousand redraws.
    static let redrawInterval: TimeInterval = 0.1

    /// How often the timer redraws when no event arrives, so the clock moves under a
    /// long compile.
    static let tickInterval: TimeInterval = 1

    private let lock = NSLock()
    private let enabled: Bool
    private let write: (String) -> Void
    private let now: () -> Date

    private var startedAt: Date?
    private var record: ProgressRecord?
    private var drawnAt: Date?
    private var isDrawn = false
    private var timer: DispatchSourceTimer?

    /// `write` puts text on the terminal as given, with no newline of its own; `now` is
    /// the clock, replaceable so a test can move it.
    init(enabled: Bool,
         write: @escaping (String) -> Void = IndicatorLine.writeToStandardOutput,
         now: @escaping () -> Date = Date.init) {
        self.enabled = enabled
        self.write   = write
        self.now     = now
    }

    /// Through C stdio, as `print` goes, so the line and the lines around it keep their
    /// order in one buffer; flushed, because there is no newline to flush it.
    static func writeToStandardOutput(_ text: String) {
        fputs(text, stdout)
        fflush(stdout)
    }

    // MARK: - The wait

    /// A wait began: the clock starts, and the next event or tick draws.
    ///
    /// `latest` is where a settle already under way stood at its last event, drawn at
    /// once: a wait begun mid-settle, or a `watch`, would otherwise show nothing until the
    /// next node starts or finishes, which under a long compile is minutes.
    func begin(showing latest: ProgressRecord? = nil) {
        guard enabled else {
            return
        }
        lock.withLock {
            let current = now()
            startedAt = current
            record    = latest
            drawnAt   = nil
            if latest != nil {
                draw(at: current)
            }
        }
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "semel.progress"))
        source.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval)
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        lock.withLock { timer = source }
    }

    /// The wait ended: the line is erased, and whatever the command prints lands on a
    /// clean line.
    func end() {
        guard enabled else {
            return
        }
        let source: DispatchSourceTimer? = lock.withLock {
            eraseIfDrawn()
            startedAt = nil
            record    = nil
            defer { timer = nil }
            return timer
        }
        source?.cancel()
    }

    /// Where the settle stands now. Drawn at once when the last drawing is old enough,
    /// else kept for the next tick.
    func update(_ record: ProgressRecord) {
        guard enabled else {
            return
        }
        lock.withLock {
            guard startedAt != nil else {
                return
            }
            self.record = record
            let current = now()
            if let drawnAt, current.timeIntervalSince(drawnAt) < Self.redrawInterval {
                return
            }
            draw(at: current)
        }
    }

    /// The timer's redraw: the clock has moved even if nothing else has.
    func tick() {
        lock.withLock {
            guard startedAt != nil, record != nil else {
                return
            }
            draw(at: now())
        }
    }

    /// Runs `body`, which prints, with the line out of the way: erased before, drawn
    /// again after, so a notice or an error report lands on a line of its own above it.
    func interrupting(_ body: () -> Void) {
        guard enabled else {
            body()
            return
        }
        lock.withLock {
            eraseIfDrawn()
            body()
            if startedAt != nil, record != nil {
                draw(at: now())
            }
        }
    }

    // MARK: - Drawing

    /// Under the lock.
    private func draw(at time: Date) {
        guard let startedAt, let record else {
            return
        }
        write(Self.erase + ProgressLineRenderer.line(record, elapsed: time.timeIntervalSince(startedAt)))
        drawnAt = time
        isDrawn = true
    }

    /// Under the lock.
    private func eraseIfDrawn() {
        guard isDrawn else {
            return
        }
        write(Self.erase)
        isDrawn = false
    }
}
