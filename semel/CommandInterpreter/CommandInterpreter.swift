// CommandInterpreter.swift
// semel

import Foundation
import SemelNodeKit
import SemelProtocol

enum CommandInterpreterError: Error {
    case quit
}

/// A rejected handshake, with what the server said so the user can act on it.
public enum ConnectError: Error, CustomStringConvertible {
    case rejected(HelloRejection)
    case unexpectedReply

    public var description: String {
        switch self {
        case .rejected(.versionMismatch(let client, let server)):
            return "this semel speaks protocol version \(client) but the server speaks \(server)"
        case .rejected(.roleNotOffered(let role)):
            return "the server does not offer the \(role.rawValue) role"
        case .unexpectedReply:
            return "the server did not answer the handshake"
        }
    }
}

public final class CommandInterpreter: CommandContext {

    let connection: any SemelConnection
    var baseDirectory: String

    /// Where `build` puts its products when `--into` is not given: `<base>/semel-out/<folder>`.
    public static let defaultExportFolder = "semel-out"

    var pushExclusions: Set<String> = [defaultExportFolder]
    var currentFileSystem: FileSystemForCommand = .input
    var currentDirectoryPath: Path = .empty
    var openBatchDepth = 0

    /// Where lines go: the terminal, unless a test wants to read them.
    public var output: (String) -> Void = { print($0) }

    /// The progress line, or the dashboard, drawn while a command of this client waits for
    /// a settle (B-95).
    /// Every line the interpreter prints steps around it, so a notice or an error report
    /// arriving mid-wait lands above it rather than through it.
    private let indicator: IndicatorLine

    func outputMessage(_ message: String) {
        indicator.interrupting { output(message) }
    }
    func outputError(_ errorMessage: String) {
        errorsLock.withLock { errorsReportedStorage += 1 }
        indicator.interrupting { output(errorMessage) }
    }

    func settleWaitBegan() { indicator.begin(showing: settleInProgress) }
    func settleWaitEnded() { indicator.end() }

    /// Reads the key that ends a `watch`. Standard input unless a test puts a script here.
    var keyReader: any KeyReader = TerminalKeyReader()

    /// The last progress event of the settle under way, and the count of settles finished,
    /// as the events have told them. Under `settleLock`: events arrive on the connection's
    /// thread, and `watch` reads both from the command thread while it waits for a key.
    private let settleLock = NSLock()
    private var settleInProgressStorage: ProgressRecord?
    private var settlesFinishedStorage = 0

    var settleInProgress: ProgressRecord? { settleLock.withLock { settleInProgressStorage } }
    var settlesFinished: Int { settleLock.withLock { settlesFinishedStorage } }

    /// Whether the idle-time error report is printed as it arrives. Off for the length of
    /// a `build`, which prints the report once at its end: a settle the follow loop
    /// answers by pushing what it named is not printed at all, and one that stands is
    /// printed by `errors` rather than twice (B-110). Counted either way, so the exit
    /// status is what it was. Under `errorsLock`: events arrive on the connection's thread.
    private var printsErrorEventsStorage = true
    private var printsErrorEvents: Bool {
        get { errorsLock.withLock { printsErrorEventsStorage } }
        set { errorsLock.withLock { printsErrorEventsStorage = newValue } }
    }

    /// The totals of the settles a `build` has seen so far, held rather than printed while
    /// the build runs: a settle the follow loop answers by pushing what it named would
    /// otherwise print a failing line just before the push that fixes it (B-110). The
    /// build prints one line at its end — the work summed over its settles, the errors of
    /// the last, which is the verdict. Nil when no build is holding. Under `errorsLock`:
    /// events arrive on the connection's thread.
    private var heldSettleStorage: (scheduled: Int, computed: Int, fromCache: Int, errors: Int)?

    /// Starts holding settle summaries, with nothing held yet.
    private func holdSettleSummaries() {
        errorsLock.withLock { heldSettleStorage = (0, 0, 0, 0) }
    }

    /// Stops holding, and returns the one line the held settles come to, if any did work.
    private func releaseSettleSummaries() -> String? {
        let held = errorsLock.withLock { () -> (scheduled: Int, computed: Int, fromCache: Int, errors: Int)? in
            defer { heldSettleStorage = nil }
            return heldSettleStorage
        }
        guard let held else {
            return nil
        }
        return SettleSummaryRenderer.line(scheduled: held.scheduled, computed: held.computed,
                                          fromCache: held.fromCache, errors: held.errors)
    }

    /// Adds one settle to what a build holds, and says whether it was held.
    private func holdSettle(scheduled: Int, computed: Int, fromCache: Int, errors: Int) -> Bool {
        errorsLock.withLock {
            guard let held = heldSettleStorage else {
                return false
            }
            heldSettleStorage = (held.scheduled + scheduled, held.computed + computed,
                                 held.fromCache + fromCache, errors)
            return true
        }
    }

    /// Forgets what was counted since `count`: a settle report the follow loop answers by
    /// pushing what it named is not this build's verdict, the settle after it is.
    private func resetErrorsReported(to count: Int) {
        errorsLock.withLock { errorsReportedStorage = count }
    }

    /// Guards `errorsReportedStorage` and `hasCountedErrorRecordsSinceReset`. The exit
    /// status a scripted run gets rests on the count, and it is written from two
    /// threads: the command thread, through `outputError`, and a connection's event
    /// thread, through `countErrorRecords` (called from `printEvent`) — the socket's
    /// reader thread over a real connection, or the engine's cooperative-pool task
    /// through `InProcessConnection`. The `build` macro's own push/wait/errors ordering
    /// happens to serialise these on that one path, but a plain `wait` racing a `push`'s
    /// own error report does not, so the count needs its own lock rather than relying on
    /// the transport to have already made it coherent.
    private let errorsLock = NSLock()

    private var errorsReportedStorage = 0

    /// How many errors commands have reported so far. A non-interactive run exits non-zero
    /// when this is not zero, which is what makes `semel 'build Packages'` a build step.
    public var errorsReported: Int { errorsLock.withLock { errorsReportedStorage } }

    /// Whether a settle report has already added to `errorsReported` once since the last
    /// `resetErrorRecordAccounting()` — the reset is per `wait`. See `countErrorRecords`.
    /// Guarded by `errorsLock` alongside the count itself.
    private var hasCountedErrorRecordsSinceReset = false

    /// The idle-time event calls this with what it is about to print, and the `errors`
    /// verb calls it with what it just printed; either way this is where a report becomes
    /// part of the exit status, once since the last reset (per `wait`) rather than once
    /// per caller.
    func countErrorRecords(_ records: [ErrorRecord]) {
        guard !records.isEmpty else { return }
        errorsLock.withLock {
            guard !hasCountedErrorRecordsSinceReset else { return }
            hasCountedErrorRecordsSinceReset = true
            errorsReportedStorage += 1
        }
    }

    func resetErrorRecordAccounting() {
        errorsLock.withLock { hasCountedErrorRecordsSinceReset = false }
    }

    private let plugins: [any CommandPlugin]

    private lazy var verbMap: [String: any CommandPlugin] = {
        var map: [String: any CommandPlugin] = [:]
        for plugin in plugins {
            for verb in plugin.verbs { map[verb] = plugin }
        }
        return map
    }()

    /// `progress` is the terminal's decision, made by `main` from
    /// `ProgressPolicy.modeInThisProcess()`; off by default so that a test's output is the
    /// lines and nothing else.
    public convenience init(connection: any SemelConnection,
                            baseDirectory: String = FileManager.default.currentDirectoryPath,
                            progress: ProgressPolicy.Mode = .off) {
        self.init(connection: connection,
                  baseDirectory: baseDirectory,
                  plugins: [NavigationPlugin(), FilePlugin(), EnginePlugin(), SessionPlugin()],
                  progress: progress)
    }

    required init(connection: any SemelConnection,
                  baseDirectory: String,
                  plugins: [any CommandPlugin],
                  progress: ProgressPolicy.Mode = .off) {
        self.connection    = connection
        self.baseDirectory = baseDirectory
        self.plugins       = plugins
        self.indicator     = IndicatorLine(mode: progress)
    }

    // MARK: - Handshake

    /// Says hello, subscribes to events, and starts printing them. Returns what the banner
    /// needs. Events arrive on the connection's thread and are printed from there.
    public func connect() throws -> (serverVersion: String, databasePath: String) {
        let (reply, _) = try connection.send(.hello(Hello(role: .daemon)), body: nil)
        guard case .hello(let helloResponse) = reply else {
            throw ConnectError.unexpectedReply
        }
        switch helloResponse {
        case .rejected(let reason):
            throw ConnectError.rejected(reason)
        case .accepted(let serverVersion, let databasePath):
            connection.onEvent = { [weak self] event in self?.printEvent(event) }
            _ = try request(.subscribe)
            return (serverVersion, databasePath)
        }
    }

    private func printEvent(_ event: Event) {
        switch event {
        case .daemon(.errors(let records)):
            if printsErrorEvents {
                records.flatMap(ErrorRecordRenderer.lines(for:)).forEach { outputMessage($0) }
            }
            countErrorRecords(records)
        case .daemon(.notice(let line)):
            outputMessage(line)
        case .daemon(.settled(let scheduled, let computed, let fromCache, let errors)):
            // Before anything prints, and whether or not a build holds the line: the
            // settle is over either way, and a `watch` ends on it.
            settleLock.withLock {
                settleInProgressStorage = nil
                settlesFinishedStorage += 1
            }
            guard !holdSettle(scheduled: scheduled, computed: computed, fromCache: fromCache, errors: errors) else {
                return
            }
            guard let line = SettleSummaryRenderer.line(scheduled: scheduled,
                                                        computed:  computed,
                                                        fromCache: fromCache,
                                                        errors:    errors) else {
                return
            }
            outputMessage(line)
        case .daemon(.artifacts(let appeared, let changed, let disappeared)):
            ArtifactChangeRenderer.lines(appeared: appeared, changed: changed, disappeared: disappeared)
                .forEach { outputMessage($0) }
        case .daemon(.progress(let record)):
            settleLock.withLock { settleInProgressStorage = record }
            indicator.update(record)
        }
    }

    // MARK: - Commands

    /// What one command line came to. `failed` means the command reported at least one
    /// error; `quit` means the session is over and the loop feeding commands should stop.
    public enum HandleCommandResult: Equatable {
        case success
        case failed
        case quit
    }

    /// Runs one command line. Errors are printed and counted, never thrown; the caller
    /// reads the outcome from the result.
    @discardableResult
    public func handleCommand(_ command: String) -> HandleCommandResult {
        let errorsBefore = errorsReported
        do {
            try run(command)
        } catch CommandInterpreterError.quit {
            return .quit
        } catch {
            outputError(Self.userFacingMessage(for: error))
        }
        return errorsReported == errorsBefore ? .success : .failed
    }

    /// What a failure is shown as.
    ///
    /// Interpolation rather than `localizedDescription`, because the errors that reach here
    /// are Swift enums: `localizedDescription` answers for one only if it conforms to
    /// `LocalizedError`, and for the rest it is "The operation couldn't be completed.
    /// (SemelCLI.ConnectError error 0.)" — a sentence that names neither the failure nor
    /// anything to do about it. Interpolation prints the `CustomStringConvertible`
    /// description these types carry; a Foundation error prints its own message with its
    /// domain and code around it, which is more than it said before, not less.
    static func userFacingMessage(for error: Error) -> String {
        "\(error)"
    }

    /// Only `CommandInterpreterError.quit` escapes; every other error is reported here so
    /// a macro's later steps still run after an earlier one failed.
    private func run(_ command: String) throws {
        var tokens = tokenize(command)
        guard !tokens.isEmpty else {
            return
        }
        if tokens.first == "semel" { tokens.removeFirst() }
        guard let verb = tokens.first else {
            return
        }
        let remaining = Array(tokens.dropFirst())

        if verb == "help" {
            printHelp(about: remaining.first)
            return
        }

        // `build <folder> [--into <dir>] [--no-follow]` is the whole loop in one word: push
        // the tree, wait for the graph to settle, push what the formula turned out to need
        // from the rest of the tree, report, and export the products — to `--into`, or to
        // `semel-out/<folder>` under the base. A macro over the commands rather than a
        // plugin, so each keeps its own meaning and its own tests. No export after a build
        // that reported errors: the exit status already says it failed, and a partial
        // product set beside it would only mislead.
        if verb == "build" {
            var arguments = remaining
            var destination: String?
            if let flag = arguments.firstIndex(of: "--into") {
                guard flag + 1 < arguments.count else {
                    outputError("build: --into needs a directory")
                    return
                }
                destination = arguments[flag + 1]
                arguments.removeSubrange(flag...(flag + 1))
            }
            let follows = !arguments.contains("--no-follow")
            arguments.removeAll { $0 == "--no-follow" }
            guard arguments.count == 1 else {
                outputError("build: expected one folder to build")
                return
            }
            let folder = arguments[0]
            let errorsBefore = errorsReported
            printsErrorEvents = false
            defer { printsErrorEvents = true }
            holdSettleSummaries()
            defer { _ = releaseSettleSummaries() }
            try run("push \(folder)")
            let errorsBeforeSettle = errorsReported
            try run("wait")
            if follows {
                try followSources(neededBy: folder, errorsBeforeSettle: errorsBeforeSettle)
            }
            if let summary = releaseSettleSummaries() {
                outputMessage(summary)
            }
            try run("errors")
            let exportFolder = destination
                ?? (baseDirectory as NSString).appendingPathComponent("\(Self.defaultExportFolder)/\(folder)")
            // A destination inside the tree is a folder a later push must leave alone, as
            // the default one is.
            if let inTree = Self.relativePath(of: exportFolder, under: baseDirectory) {
                pushExclusions.insert(inTree)
            }
            guard errorsReported == errorsBefore else {
                if let hint = prepareHint(for: folder) {
                    outputMessage(hint)
                }
                return
            }
            // A named destination with nothing to put in it is `export`'s error to report;
            // the default one is only used when there is something to put in it.
            if try destination != nil || hasProducts(folder) {
                try run("export \(folder) --into \(exportFolder)")
            } else {
                outputMessage("Nothing to export: the build published no products.")
            }
            return
        }

        do {
            guard let plugin = verbMap[verb] else {
                let known = Set(verbMap.keys).union(["build", "help"])
                throw CommandParserError.unknownCommand(verb, suggestion: Self.nearestVerb(to: verb, among: known))
            }
            try plugin.handle(verb: verb, tokens: remaining, context: self)
        } catch CommandInterpreterError.quit {
            throw CommandInterpreterError.quit
        } catch let error as ServerError {
            outputError(error.description)
        } catch {
            outputError(Self.userFacingMessage(for: error))
        }
    }

    // MARK: - help

    /// One entry per command: the verbs it answers to, how it is spelled, what it does.
    struct HelpEntry {
        let verbs:       [String]
        let usage:       String
        let description: String
    }

    /// Every command, grouped as the README groups them. `help <verb>` is the entries
    /// that answer to that verb.
    static let help: [(group: String, entries: [HelpEntry])] = [
        ("Build", [
            HelpEntry(verbs: ["build"], usage: "build <folder> [--into <dir>] [--no-follow]",
                      description: "push the folder, wait, report; push what its formula needs from the tree; "
                                 + "export the products, to semel-out/<folder> under the base unless --into says where"),
            HelpEntry(verbs: ["wait"], usage: "wait",
                      description: "block until the build has settled; at a terminal a line shows where it stands, "
                                 + "and SEMEL_PROGRESS=full lists the running nodes under it"),
            HelpEntry(verbs: ["watch"], usage: "watch",
                      description: "show where the settle stands until a key is pressed or the settle ends; "
                                 + "a key leaves it running and says where it stood"),
            HelpEntry(verbs: ["errors", "e"], usage: "errors", description: "the current build errors, one entry per cause"),
            HelpEntry(verbs: ["explain", "why"], usage: "explain <path>",
                      description: "why the last settle rebuilt a product: what ran, what came from the cache, "
                                 + "which wires changed, down to the sources"),
            HelpEntry(verbs: ["check"], usage: "check",
                      description: "report every graph invariant that does not hold; ask it of a settled graph"),
            HelpEntry(verbs: ["collect"], usage: "collect",
                      description: "delete every stored object nothing refers to; the engine does this as the store grows"),
            HelpEntry(verbs: ["tools", "t"], usage: "tools [<prefix>] [--platform <platform>]",
                      description: "the installed tools as config settings, as the machine file holds them"),
            HelpEntry(verbs: ["debug", "d"], usage: "debug [<cache key>]",
                      description: "dump the graph, or one cache entry's key material"),
            HelpEntry(verbs: ["nudge", "n"], usage: "nudge", description: "reschedule every node"),
            HelpEntry(verbs: ["reset"], usage: "reset [--cache]",
                      description: "discard everything derived and rebuild it; --cache discards the cached builds too"),
        ]),
        ("Files", [
            HelpEntry(verbs: ["push"], usage: "push <path>",
                      description: "send a file or folder under the base into the input file system"),
            HelpEntry(verbs: ["rm", "remove"], usage: "rm <path>", description: "remove a pushed file or folder"),
            HelpEntry(verbs: ["cp", "copy"], usage: "cp <path> [<destination>]",
                      description: "copy a file out of the input or output file system"),
            HelpEntry(verbs: ["export"], usage: "export <folder> --into <dir>", description: "copy a build's products out"),
        ]),
        ("Navigation", [
            HelpEntry(verbs: ["ls", "list"], usage: "ls [<pattern>]", description: "list a folder, with each entry's state"),
            HelpEntry(verbs: ["cd"], usage: "cd <folder>", description: "move about the input or output file system"),
            HelpEntry(verbs: ["pwd"], usage: "pwd", description: "where you are"),
        ]),
        ("Session", [
            HelpEntry(verbs: ["base"], usage: "base [<path>]",
                      description: "show or set the tree pushes are read from; the current directory unless set"),
            HelpEntry(verbs: ["begin", "commit"], usage: "begin … commit",
                      description: "hold the engine across several pushes, so it settles once"),
            HelpEntry(verbs: ["quit", "q", "exit"], usage: "quit", description: "leave the prompt"),
            HelpEntry(verbs: ["stop"], usage: "semel stop",
                      description: "end the engine semel started; the next semel starts one"),
        ]),
    ]

    private func printHelp(about verb: String?) {
        var found = false
        for section in Self.help {
            let matching = verb.map { needle in section.entries.filter { $0.verbs.contains(needle) } } ?? section.entries
            guard !matching.isEmpty else {
                continue
            }
            found = true
            outputMessage("\(section.group):")
            let width = matching.map(\.usage.count).max() ?? 0
            for entry in matching {
                outputMessage("  \(entry.usage.padding(toLength: width, withPad: " ", startingAt: 0))   \(entry.description)")
            }
        }
        if let verb, !found {
            outputError("help: no command named \(verb)")
        }
    }

    /// The verb `typed` is nearest to, when one is near enough to be what was meant: one
    /// edit for a word of up to three letters, two beyond that — a swapped pair is two.
    /// A one-letter alias is never offered as a guess.
    static func nearestVerb(to typed: String, among verbs: Set<String>) -> String? {
        let candidates = verbs.sorted().filter { $0.count > 1 }.map { (verb: $0, distance: editDistance(typed, $0)) }
        guard let best = candidates.min(by: { ($0.distance, $0.verb) < ($1.distance, $1.verb) }),
              best.distance <= (typed.count <= 3 ? 1 : 2) else {
            return nil
        }
        return best.verb
    }

    private static func editDistance(_ left: String, _ right: String) -> Int {
        let leftChars  = Array(left)
        let rightChars = Array(right)
        var previous = Array(0...rightChars.count)
        for (leftIndex, leftChar) in leftChars.enumerated() {
            var current = [leftIndex + 1]
            for (rightIndex, rightChar) in rightChars.enumerated() {
                let substitution = previous[rightIndex] + (leftChar == rightChar ? 0 : 1)
                current.append(min(previous[rightIndex + 1] + 1, current[rightIndex] + 1, substitution))
            }
            previous = current
        }
        return previous[rightChars.count]
    }

    // MARK: - Following the formula's inputs (B-110)

    /// `build` follows the formula's inputs within the tree. A settle that reports a source
    /// nobody has pushed names it as `push` takes it; when that path exists under `base`,
    /// this pushes it — saying which formula asked — and waits again, until a round finds
    /// nothing new to push.
    ///
    /// Never outside `base`: a path in the input file system is a path under `base` by
    /// construction, so the fence needs no check here. Never unasked: only what a node
    /// reported absent by name, so an unrelated folder beside the project stays where it
    /// is. Only what exists: a path missing on disk stays the error it is. Bounded: a path
    /// is pushed once, so a round that finds only paths already tried is the last.
    private func followSources(neededBy folder: String, errorsBeforeSettle: Int) throws {
        var pushed: Set<String> = []
        var errorsBeforeSettle = errorsBeforeSettle
        while true {
            guard case .errors(let records) = try request(.errors).0 else {
                return
            }
            let missing = records
                .flatMap { $0.entries.compactMap(\.missingSource) }
                .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            let onDisk = missing.filter { path in
                !pushed.contains(path)
                    && FileManager.default.fileExists(atPath: (baseDirectory as NSString).appendingPathComponent(path))
            }
            guard !onDisk.isEmpty else {
                return
            }

            // The settle just reported what this round supplies, so its report is not the
            // build's verdict; a push that fails below still counts.
            resetErrorsReported(to: errorsBeforeSettle)

            // The report names paths from the root of the input file system, and `push`
            // reads its argument from the session's current directory; for these pushes
            // the two are made the same.
            let currentDirectoryBefore = currentDirectoryPath
            currentDirectoryPath = .empty
            defer { currentDirectoryPath = currentDirectoryBefore }

            let formula = formulaName(in: folder)
            for path in Set(onDisk).sorted() {
                outputMessage("\(formula) needs \(Self.relativePath(to: path, from: folder))")
                try run("push \(path)")
                pushed.insert(path)
            }
            errorsBeforeSettle = errorsReported
            try run("wait")
        }
    }

    /// The one command a failed build of a Swift tree with no configuration needs next.
    /// `prepare` is that tree's command — it vendors the dependencies and writes the
    /// formula and the config — and the report is where a reader looks for what to do.
    /// Decided from the disk, which the client can read and the report cannot.
    private func prepareHint(for folder: String) -> String? {
        let folderPath = (baseDirectory as NSString).appendingPathComponent(folder)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folderPath)) ?? []
        guard !contents.contains("semel.config") else {
            return nil
        }
        if contents.contains { $0.hasSuffix(".xcodeproj") } {
            return "\(folder) holds an Xcode project and no semel.config: "
                 + "`semel-swift prepare \(folder) --platform ios-simulator` writes one; then build again."
        }
        if contents.contains("Package.swift") {
            return "\(folder) holds a Package.swift and no semel.config: "
                 + "`semel-swift prepare \(folder) --platform macos` writes one; then build again."
        }
        return nil
    }

    /// Whether the output file system holds a folder for what was built: the products
    /// `export` would copy.
    private func hasProducts(_ folder: String) throws -> Bool {
        let outputFolder = resolve(folder, relativeTo: .empty).string
        guard case .list(let matches) = try request(.list(fileSystem: .output, pattern: outputFolder)).0 else {
            return false
        }
        return matches.contains { $0.kind == .folder }
    }

    /// What asked for a source: the one formula file in the folder being built, or the
    /// folder when it holds none or several.
    private func formulaName(in folder: String) -> String {
        let folderPath = (baseDirectory as NSString).appendingPathComponent(folder)
        let formulas = ((try? FileManager.default.contentsOfDirectory(atPath: folderPath)) ?? [])
            .filter { $0.hasSuffix(".fmla") }
        guard formulas.count == 1, let formula = formulas.first else {
            return folder
        }
        return (folder as NSString).appendingPathComponent(formula)
    }

    /// `path` relative to `base` when it lies under it, else nil. Both are taken as the file
    /// system spells them, so `out/../out` and `./out` are one folder.
    static func relativePath(of path: String, under base: String) -> String? {
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        let root   = URL(fileURLWithPath: base).standardizedFileURL.path
        guard target != root, target.hasPrefix(root + "/") else {
            return nil
        }
        return String(target.dropFirst(root.count + 1))
    }

    /// `path` as seen from `folder`, both relative to `base`: `clang.cfg` from `hello` is
    /// `../clang.cfg`, which is how the formula spelled it.
    static func relativePath(to path: String, from folder: String) -> String {
        let target = Path(path).segments
        let origin = Path(folder).segments
        let shared = zip(target, origin).prefix { $0 == $1 }.count
        let up = Array(repeating: "..", count: origin.count - shared)
        return (up + target.dropFirst(shared)).joined(separator: "/")
    }

    // MARK: - Tokenizer

    private func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false

        for char in command {
            if char == "\"" {
                inQuotes.toggle()
            } else if char.isWhitespace && !inQuotes {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}

enum FileSystemForCommand {
    case input
    case output

    /// The wire's name for this file system.
    var kind: FileSystemKind {
        switch self {
        case .input:  return .input
        case .output: return .output
        }
    }

    /// The root segment every path in it begins with.
    var rootName: String {
        switch self {
        case .input:  return FileSystemName.input
        case .output: return FileSystemName.output
        }
    }
}

enum CommandParserError: Error, LocalizedError {
    case unknownCommand(String, suggestion: String?)
    case missingArgument(command: String, expected: String)
    case tooManyArguments(command: String)
    case unknownOption(command: String, option: String)

    var errorDescription: String? {
        switch self {
        case .unknownCommand(let cmd, let suggestion):
            return "Unknown command: \(cmd)" + (suggestion.map { " — did you mean \($0)? `help` lists them all" } ?? "; `help` lists them")
        case .missingArgument(let cmd, let expected):
            return "\(cmd): missing argument (\(expected))"
        case .tooManyArguments(let cmd):
            return "\(cmd): too many arguments"
        case .unknownOption(let cmd, let option):
            return "\(cmd): unknown option '\(option)'"
        }
    }
}

/// The interpreter prints `"\(error)"`, which reaches `description` and never
/// `errorDescription`, so the sentences above are said through this.
extension CommandParserError: CustomStringConvertible {
    // Not `"\(self)"` as the fallback: interpolating a `CustomStringConvertible` calls
    // `description`, so that would recurse. Every case answers a sentence, so it is a
    // fallback no case reaches.
    var description: String { errorDescription ?? "the command could not be parsed" }
}
