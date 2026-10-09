// Watcher.swift
// SemelWatch
//
// One watcher: one stream of changes, one interpreter, and the loop between them (B-126).
//
// The watcher runs the commands a person runs — `begin`, `rm`, `push`, `commit`, `errors`,
// `export` — through a `CommandInterpreter`, in process, rather than speaking the protocol
// itself. A change to what a push does reaches it for free, it reports exactly as `semel`
// reports, and a transcript of what it did reads like a session.

import Foundation
import SemelCLI
import SemelNodeKit
import SemelProtocol

/// A connection to the engine with an interpreter over it, the handshake done.
public struct WatchSession {
    public let interpreter: CommandInterpreter
    public let serverVersion: String
    public let databasePath: String
    /// Whether the connection can still carry a request. A socket's goes false when the
    /// engine stops; the watcher then opens another.
    public let isOpen: () -> Bool

    public init(interpreter: CommandInterpreter, serverVersion: String, databasePath: String,
                isOpen: @escaping () -> Bool) {
        self.interpreter   = interpreter
        self.serverVersion = serverVersion
        self.databasePath  = databasePath
        self.isOpen        = isOpen
    }
}

/// Opens a session: over a socket, starting `semelserv` when none answers, in
/// `semel-watch`; over an in-process server in a test.
public protocol WatchConnector {
    func connect() throws -> WatchSession
}

public final class Watcher {

    public let configuration: WatchConfiguration

    /// Where every line goes — the watcher's own and the interpreter's: standard output,
    /// unless a test wants to read them.
    public var output: (String) -> Void = { print($0) }

    /// How many batches have been issued, the initial one among them.
    public private(set) var batchesIssued = 0

    private let events: any FileEvents
    private let clock: any WatchClock
    private let connector: any WatchConnector
    private let disk: any FileWildcardMatcherInput

    private var filter: WatchFilter
    private var coalescer: ChangeCoalescer
    private var session: WatchSession?

    /// The longest wait between two attempts to reach an engine that has gone.
    static let longestReconnectDelay = Duration.seconds(5)

    /// `disk` is the tree as a push lists it, `ExternalFileSystemLister` over the base
    /// unless a test gives another.
    public init(configuration: WatchConfiguration, events: any FileEvents, clock: any WatchClock,
                connector: any WatchConnector, disk: (any FileWildcardMatcherInput)? = nil) {
        self.configuration = configuration
        self.events        = events
        self.clock         = clock
        self.connector     = connector
        self.disk          = disk ?? ExternalFileSystemLister(rootDirectoryPath: configuration.base)
        self.filter        = configuration.filter
        self.coalescer     = ChangeCoalescer(quietInterval: configuration.quietInterval)
    }

    // MARK: - The loop

    /// Connects, says what is watched, mirrors the tree once — removing what the graph
    /// holds and the disk lacks, then pushing every watched folder, in one batch — and then
    /// issues one batch per burst of changes until the stream ends. Throws only when the
    /// first connection fails: a watcher that never reached an engine has nothing to watch
    /// for.
    public func run() throws {
        let opened = try connector.connect()
        adopt(opened)
        output("Semel \(opened.serverVersion)")
        output("Graph: \(opened.databasePath)")

        if configuration.pushesInitially {
            issue(nil, announcing: true)
        } else {
            output(launchLine(mirrored: nil))
        }
        while true {
            let timeout = coalescer.dueAt.map { max(.zero, $0 - clock.now) }
            switch events.next(waitingAtMost: timeout) {
            case .events(let reported):
                coalescer.record(reported, at: clock.now)
            case .timedOut:
                break
            case .ended:
                return
            }
            if let batch = coalescer.takeBatch(at: clock.now) {
                issue(batch)
            }
        }
    }

    /// What is watched, what is excepted, and when a batch goes: the line that shows a
    /// filter excepting the file being edited, and names the base so that two watchers on
    /// one are seen to be. After it, from the initial batch's plan, how many paths the
    /// graph held that the disk no longer has are removed, and how many are kept because
    /// the filter excepts them — the one place a narrowing filter shows what it spared.
    func launchLine(mirrored plan: MirrorPlan?) -> String {
        let watched = filter.roots.map { $0.isEmpty ? "." : $0.string }.joined(separator: ", ")
        var parts = ["Watching \(watched) under \(configuration.base)"]
        if filter.only != [Path(WatchFilter.everything)] {
            parts.append("only \(filter.only.map(\.string).joined(separator: ", "))")
        }
        let excepted = filter.except.map(\.string) + filter.alwaysExcepted.map { "\($0.string)/" }
        parts.append("except \(excepted.joined(separator: ", "))")
        if let destination = configuration.exportDestination {
            parts.append("exporting into \(destination) after each settle without errors")
        }
        parts.append("a batch after \(Self.spoken(configuration.quietInterval)) of quiet")
        if let plan, plan.removedCount > 0 {
            parts.append("removing \(Self.counted(plan.removedCount, "path")) the disk no longer has")
        }
        if let plan, plan.exceptedCount > 0 {
            parts.append("keeping \(Self.counted(plan.exceptedCount, "path")) the disk no longer has, "
                         + "which the filter excepts")
        }
        return parts.joined(separator: "; ") + "."
    }

    /// `1 path`, `2 paths`.
    static func counted(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    /// `2 s`, or `500 ms` for an interval that is not whole seconds.
    static func spoken(_ interval: Duration) -> String {
        let millisecondsPerSecond: Int64 = 1000
        let (seconds, attoseconds) = interval.components
        let attosecondsPerMillisecond: Int64 = 1_000_000_000_000_000
        let milliseconds = seconds * millisecondsPerSecond + attoseconds / attosecondsPerMillisecond
        guard milliseconds % millisecondsPerSecond == 0 else {
            return "\(milliseconds) ms"
        }
        return "\(milliseconds / millisecondsPerSecond) s"
    }

    // MARK: - One batch

    /// Plans `batch` — or, for nil, a mirror of everything watched — and issues it. A
    /// connection that drops before or while it is issued is reopened, and the batch
    /// issued again with a mirror of everything, since an engine that restarted may have
    /// missed what was pushed, or removed, while it was away. `announcing` is the launch:
    /// the launch line goes out once, with what the first plan removes, before the batch.
    private func issue(_ batch: ChangeBatch?, announcing: Bool = false) {
        var pushesEverything = batch == nil
        var announcing = announcing
        defer {
            if announcing {
                output(launchLine(mirrored: nil))
            }
        }
        while !events.isStopped {
            switch openSession() {
            case .stopped:
                return
            case .reopened:
                pushesEverything = true
            case .unchanged:
                break
            }
            guard let session else {
                return
            }
            let commands: [WatchCommand]
            do {
                let planned = try plan(batch ?? ChangeBatch(), mirroringEverything: pushesEverything, session: session)
                commands = planned.commands
                if announcing {
                    output(launchLine(mirrored: planned))
                    announcing = false
                }
            } catch {
                guard session.isOpen() else {
                    continue
                }
                output("semel-watch: the batch could not be planned: \(error)")
                return
            }
            guard !commands.isEmpty else {
                return
            }
            run(commands, in: session)
            guard !session.isOpen() else {
                return
            }
        }
    }

    private func plan(_ batch: ChangeBatch, mirroringEverything: Bool, session: WatchSession) throws -> MirrorPlan {
        let planner  = BatchPlanner(filter: filter)
        let holdings = InterpreterHoldings(interpreter: session.interpreter)
        guard mirroringEverything else {
            return MirrorPlan(commands: try planner.plan(batch, disk: disk, holdings: holdings),
                              removedCount: 0, exceptedCount: 0)
        }
        return try planner.planMirroring(batch, folders: configuration.folders, disk: disk, holdings: holdings)
    }

    /// One `begin` … `commit` around the batch's removals and pushes, the formula's inputs
    /// followed as `build` follows them, then the report and, with `--into`, the export.
    private func run(_ commands: [WatchCommand], in session: WatchSession) {
        let interpreter = session.interpreter
        var removals: [String] = []
        var pushes:   [String] = []
        for command in commands {
            switch command {
            case .remove(let path): removals.append(path.string)
            case .push(let path):   pushes.append(path.string)
            }
        }

        var followed: [String] = []
        interpreter.holdingReports {
            interpreter.handleCommand(verb: "begin", arguments: [])
            guard session.isOpen() else {
                return
            }
            if !removals.isEmpty {
                interpreter.handleCommand(verb: "rm", arguments: removals)
            }
            if !pushes.isEmpty {
                interpreter.handleCommand(verb: "push", arguments: pushes)
            }
            interpreter.handleCommand(verb: "commit", arguments: [])
            guard session.isOpen() else {
                return
            }
            // A formula's input outside the watched folders — a machine file beside the
            // project — is pushed as `build` pushes it, and watched from then on.
            followed = interpreter.followSources(neededBy: followFolder)
        }
        batchesIssued += 1
        for path in followed {
            filter.watch(Path(path))
        }
        guard session.isOpen() else {
            return
        }
        reportAndExport(in: session)
    }

    /// The folder the follow names a formula from: the first watched one, `.` for the base.
    private var followFolder: String {
        configuration.folders.first.map { $0.isEmpty ? "." : $0.string } ?? "."
    }

    /// The error report when the graph holds errors — this watcher's to print unless the
    /// prompt that started it prints its own — and, with `--into`, the export when it
    /// holds none. Decided from the whole graph, as `build` decides: a failure standing
    /// from an earlier settle leaves the products as broken as a new one.
    private func reportAndExport(in session: WatchSession) {
        let interpreter = session.interpreter
        let records: [ErrorRecord]
        do {
            records = try interpreter.errorRecords()
        } catch {
            output("semel-watch: could not ask the engine for its errors: \(error)")
            return
        }
        guard records.isEmpty else {
            if configuration.printsReports {
                interpreter.handleCommand(verb: "errors", arguments: [])
            }
            if let destination = configuration.exportDestination {
                output(CommandInterpreter.notExportedLine(into: destination, records: records))
            }
            return
        }
        guard let destination = configuration.exportDestination else {
            return
        }
        for folder in configuration.folders {
            interpreter.handleCommand(verb: "export", arguments: [folder.isEmpty ? "." : folder.string, "--into", destination])
        }
    }

    // MARK: - The connection

    private enum SessionState {
        case unchanged
        case reopened
        case stopped
    }

    /// The session, reopened with a growing pause between attempts when it has dropped —
    /// starting `semelserv` again, through the connector, when none answers.
    private func openSession() -> SessionState {
        if let session, session.isOpen() {
            return .unchanged
        }
        var delay = Duration.milliseconds(250)
        var saidSo = false
        while !events.isStopped {
            do {
                adopt(try connector.connect())
                output("Reconnected to the engine; mirroring everything watched again.")
                return .reopened
            } catch {
                if !saidSo {
                    output("The connection to the engine dropped (\(error)); reconnecting.")
                    saidSo = true
                }
                clock.sleep(for: delay)
                delay = min(delay * 2, Self.longestReconnectDelay)
            }
        }
        return .stopped
    }

    private func adopt(_ opened: WatchSession) {
        opened.interpreter.output = output
        for excepted in filter.alwaysExcepted {
            opened.interpreter.excludeFromPush(excepted.string)
        }
        session = opened
    }
}

/// What the graph holds, asked through the interpreter.
struct InterpreterHoldings: InputHoldings {
    let interpreter: CommandInterpreter

    func holds(_ path: Path) throws -> Bool {
        try interpreter.inputHolds(path.string)
    }

    func holdings(below folder: Path) throws -> [FileWildcardEntry] {
        try interpreter.inputHoldings(below: folder.string)
    }
}
