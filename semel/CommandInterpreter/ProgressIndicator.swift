// ProgressIndicator.swift
// semel
//
// What moves while this client waits for a settle (B-95): how far the settle has got,
// redrawn in place, erased before the command that waited prints its result. One line by
// default; with `SEMEL_PROGRESS=full`, the dashboard — that line, then one line per node
// computing now, each with how long it has been at it.
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

/// Whether anything is drawn, and how much, decided once per process from the terminal.
public enum ProgressPolicy {

    /// How much is drawn while a command waits.
    public enum Mode: Equatable, Sendable {
        /// Nothing: not a terminal, a `dumb` one, or turned off.
        case off
        /// The one line of totals.
        case line
        /// The line of totals, then one line per running node with its elapsed time.
        case dashboard
    }

    /// `SEMEL_PROGRESS=0` turns the indicator off at a terminal, for the person who wants
    /// a transcript without it; `SEMEL_PROGRESS=full` asks for the dashboard. Beside
    /// `SEMEL_JOBS`, the second setting read from the environment; not a per-command flag,
    /// because the people who see it are people at a terminal, and an option nobody knows
    /// about is an option nobody uses. The dashboard is a size of the same setting rather
    /// than a setting of its own: one variable says whether and how much.
    public static let variable = "SEMEL_PROGRESS"

    /// The value that selects the dashboard.
    static let fullValue = "full"

    /// Whether anything is drawn: a terminal, not `dumb`, not turned off.
    static func shows(environment: [String: String], standardOutputIsTerminal: Bool) -> Bool {
        guard standardOutputIsTerminal else {
            return false
        }
        guard environment["TERM"] != "dumb" else {
            return false
        }
        return environment[variable] != "0"
    }

    /// How much is drawn: nothing where `shows` says so, the dashboard for `full`, and the
    /// one line for anything else — unset, `1`, or a value this client does not know,
    /// which is no reason to take the line away.
    static func mode(environment: [String: String], standardOutputIsTerminal: Bool) -> Mode {
        guard shows(environment: environment, standardOutputIsTerminal: standardOutputIsTerminal) else {
            return .off
        }
        return environment[variable] == fullValue ? .dashboard : .line
    }

    /// The decision for this process.
    public static func modeInThisProcess() -> Mode {
        mode(environment: ProcessInfo.processInfo.environment,
             standardOutputIsTerminal: isatty(STDOUT_FILENO) == 1)
    }
}

// MARK: - Renderers

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

    /// The line as it fits `width` columns: whole when it can be, else without the split
    /// of what is done — which is what the summary will say anyway — so the clock stays
    /// on the screen, else cut. A large build's whole line is wider than eighty columns.
    static func line(_ record: ProgressRecord, elapsed: TimeInterval, fitting width: Int) -> String {
        let whole = line(record, elapsed: elapsed)
        guard TerminalText.displayWidth(whole) > width else {
            return whole
        }
        let done    = record.computed + record.fromCache
        let compact = "\(Mark.working) \(grouped(record.running.count)) running, \(grouped(record.pending)) pending · "
                    + "\(grouped(done)) done · \(duration(elapsed))"
        return TerminalText.truncatedFromRight(compact, toWidth: width)
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

/// The dashboard: the totals line, then one line per running node in start order —
/// its type, its name, how long it has been running — in columns.
///
/// Every line is cut to the terminal's width. A line that wrapped would take two rows
/// where the indicator counted one, and the erase before the next frame would go up one
/// row too few and leave the top of the old frame on the screen for good.
enum ProgressDashboardRenderer {

    /// Under the totals line, so the nodes read as its detail rather than as lines of
    /// their own.
    static let indent = "   "

    /// Between two columns.
    static let gap = "  "

    /// Rows left free below the dashboard's own: the line the cursor sits on after the
    /// command, and one so the frame never fills the screen. A frame taller than the
    /// screen scrolls its first rows out of reach of the cursor-up that erases it.
    static let reservedRows = 2

    /// The frame: the totals line, then the nodes. `nodeElapsed` is each running node's
    /// time since it started, in the order of `record.running`.
    static func lines(_ record: ProgressRecord,
                      elapsed: TimeInterval,
                      nodeElapsed: [TimeInterval],
                      size: TerminalSize) -> [String] {
        let usable    = size.usableColumns
        let nodeRows  = max(0, size.rows - reservedRows - 1)
        let running   = record.running
        var shown     = running.count
        var remainder = 0
        if running.count > nodeRows {
            shown     = max(0, nodeRows - 1)
            remainder = running.count - shown
        }
        var frame = [ProgressLineRenderer.line(record, elapsed: elapsed, fitting: usable)]
        frame += nodeLines(Array(running.prefix(shown)), elapsed: Array(nodeElapsed.prefix(shown)), width: usable)
        if remainder > 0, nodeRows > 0 {
            frame.append(TerminalText.truncatedFromRight("\(indent)and \(ProgressLineRenderer.grouped(remainder)) more",
                                                         toWidth: usable))
        }
        return frame
    }

    /// One line per node: the type padded to the longest type shown, the name padded to
    /// the longest name shown and cut from the left to fit, the elapsed time right-aligned.
    ///
    /// A name loses its start rather than its end because a path's end is what tells two
    /// running nodes apart — `…/lbaselib.c` and `…/lstrlib.c` — while its start is the
    /// same folder for most of a build.
    static func nodeLines(_ running: [ActiveNode], elapsed: [TimeInterval], width: Int) -> [String] {
        guard !running.isEmpty else {
            return []
        }
        let durations     = running.indices.map { nodeDuration($0 < elapsed.count ? elapsed[$0] : 0) }
        let typeWidth     = running.map { TerminalText.displayWidth($0.type) }.max() ?? 0
        let durationWidth = durations.map { TerminalText.displayWidth($0) }.max() ?? 0
        let fixedWidth    = indent.count + typeWidth + gap.count + gap.count + durationWidth
        let longestName   = running.map { TerminalText.displayWidth($0.name) }.max() ?? 0
        let nameWidth     = min(longestName, max(0, width - fixedWidth))

        return zip(running, durations).map { node, duration in
            let type = TerminalText.padded(node.type, toWidth: typeWidth)
            let name = TerminalText.padded(TerminalText.truncatedFromLeft(node.name, toWidth: nameWidth),
                                           toWidth: nameWidth)
            let time = String(repeating: " ", count: durationWidth - TerminalText.displayWidth(duration)) + duration
            return TerminalText.truncatedFromRight(indent + type + gap + name + gap + time, toWidth: width)
        }
    }

    /// `4.2 s` under a minute — a compile is seconds, and tenths show it moving — then
    /// the totals line's `1m 32s`. Cut rather than rounded, as the totals' clock is, so
    /// a node never shows a tenth it has not had.
    static func nodeDuration(_ elapsed: TimeInterval) -> String {
        let clamped = max(0, elapsed)
        guard clamped < 60 else {
            return ProgressLineRenderer.duration(clamped)
        }
        let tenths = Int(clamped * 10)
        return "\(tenths / 10).\(tenths % 10) s"
    }
}

// MARK: - The terminal's measures

/// How big the terminal is, read once per drawing so a resize is followed.
struct TerminalSize: Equatable {
    let columns: Int
    let rows: Int

    /// What a terminal that will not say is taken to be.
    static let fallback = TerminalSize(columns: 80, rows: 24)

    /// One column short of the width: a line that ends in the last column leaves some
    /// terminals waiting to wrap, and the next newline then moves two rows, not one.
    var usableColumns: Int { max(1, columns - 1) }

    /// Standard output's window size, or the fallback when it is not a terminal or
    /// reports zero.
    static func ofStandardOutput() -> TerminalSize {
        var window = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &window) == 0, window.ws_col > 0, window.ws_row > 0 else {
            return fallback
        }
        return TerminalSize(columns: Int(window.ws_col), rows: Int(window.ws_row))
    }
}

/// Widths as the terminal counts them, in columns rather than characters: the `⏳` that
/// opens the totals line takes two.
enum TerminalText {

    /// Two columns for a character shown as an emoji and for the wide East Asian ranges,
    /// one for anything else. Not the full Unicode width tables — a file name in the running list
    /// is Latin text nearly always — but enough that the totals line is measured right.
    static func columns(of character: Character) -> Int {
        for scalar in character.unicodeScalars {
            if scalar.properties.isEmojiPresentation || scalar.value == 0xFE0F {
                return 2
            }
            if isWide(scalar.value) {
                return 2
            }
        }
        return 1
    }

    private static func isWide(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    static func displayWidth(_ text: String) -> Int {
        text.reduce(0) { $0 + columns(of: $1) }
    }

    /// `text` with `…` in place of its start, as much of its end kept as fits `width`.
    static func truncatedFromLeft(_ text: String, toWidth width: Int) -> String {
        guard displayWidth(text) > width else {
            return text
        }
        guard width > 0 else {
            return ""
        }
        var kept: [Character] = []
        var used = 1
        for character in text.reversed() {
            let characterWidth = columns(of: character)
            guard used + characterWidth <= width else {
                break
            }
            kept.append(character)
            used += characterWidth
        }
        return "…" + String(kept.reversed())
    }

    /// `text` with `…` in place of its end, as much of its start kept as fits `width`.
    static func truncatedFromRight(_ text: String, toWidth width: Int) -> String {
        guard displayWidth(text) > width else {
            return text
        }
        guard width > 0 else {
            return ""
        }
        var kept = ""
        var used = 1
        for character in text {
            let characterWidth = columns(of: character)
            guard used + characterWidth <= width else {
                break
            }
            kept.append(character)
            used += characterWidth
        }
        return kept + "…"
    }

    /// `text` with spaces after it up to `width` columns.
    static func padded(_ text: String, toWidth width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - displayWidth(text)))
    }
}

// MARK: - Elapsed per node

/// When each running node started, as far as this client can tell: the record carries no
/// start times and no ids, so the first record in which a node appears stamps it, and a
/// record without it drops the stamp. Keyed by type and name, and by how many nodes of
/// that type and name come before it in the running list — two unnamed nodes of one type
/// are two stamps, and when the older finishes the younger takes its place, which is a
/// clock slightly fast on a node nobody can tell apart from its twin anyway.
struct ActiveNodeClock {

    private struct Key: Hashable {
        let type: String
        let name: String
        let occurrence: Int
    }

    private var startedAt: [Key: Date] = [:]

    private static func keys(for running: [ActiveNode]) -> [Key] {
        var seen: [Key: Int] = [:]
        return running.map { node in
            let first      = Key(type: node.type, name: node.name, occurrence: 0)
            let occurrence = seen[first, default: 0]
            seen[first] = occurrence + 1
            return Key(type: node.type, name: node.name, occurrence: occurrence)
        }
    }

    /// A record arrived at `time`: its new nodes start now, and the nodes it no longer
    /// lists are forgotten.
    mutating func observe(_ running: [ActiveNode], at time: Date) {
        let keys = Self.keys(for: running)
        var stamps: [Key: Date] = [:]
        for key in keys {
            stamps[key] = startedAt[key] ?? time
        }
        startedAt = stamps
    }

    /// How long each of `running` has been running at `time`, in its order; a node never
    /// observed has just started.
    func elapsed(of running: [ActiveNode], at time: Date) -> [TimeInterval] {
        Self.keys(for: running).map { key in
            startedAt[key].map { time.timeIntervalSince($0) } ?? 0
        }
    }
}

// MARK: - The indicator

/// The indicator on the terminal — the one line, or the dashboard's several: owned by
/// the interpreter, told when a wait begins and ends, fed each progress event, and asked
/// to step aside for anything else the client prints.
///
/// Three threads meet here — the command thread in `begin` and `end`, the connection's
/// event thread in `update` and `interrupting`, and the timer's queue in `tick` — so every
/// entry point takes the one lock, and the write to the terminal happens under it, which
/// is what keeps an erase and the frame that follows it together.
///
/// Several lines are redrawn in place by counting them: the indicator knows how many rows
/// it has on the screen, and each redraw goes up over all of them, erasing each, before
/// the new frame. The erase and the frame are one write, so the terminal never shows a
/// frame half drawn over the last.
final class IndicatorLine {

    /// Carriage return and erase the line: back to the start, wipe, and the next write
    /// lands on a clean line without scrolling.
    static let erase = "\r\u{1B}[2K"

    /// Up one row and erase it: the column stays at the start, where `erase` put it.
    static let eraseLineAbove = "\u{1B}[1A\u{1B}[2K"

    /// The sequence that clears a frame of `lines` rows with the cursor on its last row,
    /// leaving the cursor at the start of its first. At least one row: before the first
    /// frame the cursor's line is cleared, as the one line always did.
    static func erasing(lines: Int) -> String {
        erase + String(repeating: eraseLineAbove, count: max(0, lines - 1))
    }

    /// The least time between two redraws on events: a few thousand events over a build
    /// are not a few thousand redraws.
    static let redrawInterval: TimeInterval = 0.1

    /// How often the timer redraws when no event arrives, so the clock moves under a
    /// long compile.
    static let tickInterval: TimeInterval = 1

    private let lock = NSLock()
    private let mode: ProgressPolicy.Mode
    private let write: (String) -> Void
    private let now: () -> Date
    private let terminalSize: () -> TerminalSize

    private var startedAt: Date?
    private var record: ProgressRecord?
    private var drawnAt: Date?
    /// Rows the last frame put on the screen and nothing has erased since.
    private var drawnLines = 0
    private var clock = ActiveNodeClock()
    private var timer: DispatchSourceTimer?

    /// `write` puts text on the terminal as given, with no newline of its own; `now` is
    /// the clock and `terminalSize` the window, both replaceable so a test can set them.
    init(mode: ProgressPolicy.Mode,
         write: @escaping (String) -> Void = IndicatorLine.writeToStandardOutput,
         now: @escaping () -> Date = Date.init,
         terminalSize: @escaping () -> TerminalSize = TerminalSize.ofStandardOutput) {
        self.mode         = mode
        self.write        = write
        self.now          = now
        self.terminalSize = terminalSize
    }

    private var enabled: Bool { mode != .off }

    /// Through C stdio, as `print` goes, so the frame and the lines around it keep their
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
            if let latest {
                observe(latest, at: current)
                draw(at: current)
            }
        }
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "semel.progress"))
        source.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval)
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        lock.withLock { timer = source }
    }

    /// The wait ended: every row of the indicator is erased, and whatever the command
    /// prints lands on a clean line. The nodes' stamps stay: a `watch` ended by a key
    /// leaves the settle running, and a `wait` after it should show the same clocks.
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
    /// else kept for the next tick. The dashboard's stamps are taken from every record,
    /// waiting or not, so a node that started before a `wait` or a `watch` began shows the
    /// time it has really been running.
    func update(_ record: ProgressRecord) {
        guard enabled else {
            return
        }
        lock.withLock {
            let current = now()
            observe(record, at: current)
            guard startedAt != nil else {
                return
            }
            self.record = record
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

    /// Runs `body`, which prints, with the indicator out of the way: erased before, drawn
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
    private func observe(_ record: ProgressRecord, at time: Date) {
        guard mode == .dashboard else {
            return
        }
        clock.observe(record.running, at: time)
    }

    /// Under the lock. One write: the old frame's erase and the new frame together.
    private func draw(at time: Date) {
        guard let startedAt, let record else {
            return
        }
        let frame = lines(record, elapsed: time.timeIntervalSince(startedAt), at: time)
        write(Self.erasing(lines: drawnLines) + frame.joined(separator: "\n"))
        drawnAt    = time
        drawnLines = frame.count
    }

    /// Under the lock.
    private func lines(_ record: ProgressRecord, elapsed: TimeInterval, at time: Date) -> [String] {
        let size = terminalSize()
        switch mode {
        case .off:
            return []
        case .line:
            return [ProgressLineRenderer.line(record, elapsed: elapsed, fitting: size.usableColumns)]
        case .dashboard:
            return ProgressDashboardRenderer.lines(record,
                                                   elapsed:     elapsed,
                                                   nodeElapsed: clock.elapsed(of: record.running, at: time),
                                                   size:        size)
        }
    }

    /// Under the lock.
    private func eraseIfDrawn() {
        guard drawnLines > 0 else {
            return
        }
        write(Self.erasing(lines: drawnLines))
        drawnLines = 0
    }
}
