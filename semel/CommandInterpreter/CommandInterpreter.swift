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

    /// Whether error reports are drawn in colour. `main` decides from the terminal
    /// (`ColourPolicy.inThisProcess()`); off by default, so a test reads plain lines.
    public var reportsInColour = false

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

    /// Starts the `semel-watch` that `watch <folder>` asks for: the executable beside this
    /// one, unless a test records the launch instead.
    public var watcherLauncher: any WatcherLauncher = ProcessWatcherLauncher()

    /// The watcher this session started. Read and written on the command thread only.
    var runningWatcher: RunningWatcher?

    /// Stops the watcher `watch <folder>` started, if one runs. What the client calls when
    /// its session ends without a `quit` — the end of a script, or of standard input — so
    /// a watcher does not outlive the prompt that started it.
    public func stopWatcher() {
        stopRunningWatcher()
    }

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

    /// The settles a `build` has seen so far, held rather than printed while the build
    /// runs, and printed at its end as one summary with the artifact diff under it (see
    /// `HeldSettles`). Nil when no build is holding. Under `errorsLock`: events arrive on
    /// the connection's thread.
    private var heldSettlesStorage: HeldSettles?

    /// Starts holding settles, with nothing held yet.
    private func holdSettles() {
        errorsLock.withLock { heldSettlesStorage = HeldSettles() }
    }

    /// Stops holding, and returns the lines the held settles come to.
    private func releaseSettles() -> [String] {
        errorsLock.withLock {
            defer { heldSettlesStorage = nil }
            return heldSettlesStorage?.lines ?? []
        }
    }

    /// Adds one settle's summary to what a build holds, and says whether it was held.
    private func holdSettle(scheduled: Int, computed: Int, fromCache: Int, errors: Int) -> Bool {
        errorsLock.withLock {
            guard heldSettlesStorage != nil else {
                return false
            }
            heldSettlesStorage?.add(scheduled: scheduled, computed: computed, fromCache: fromCache, errors: errors)
            return true
        }
    }

    /// Adds one settle's artifact diff to what a build holds, and says whether it was held.
    private func holdArtifacts(appeared: [String], changed: [String], disappeared: [String]) -> Bool {
        errorsLock.withLock {
            guard heldSettlesStorage != nil else {
                return false
            }
            heldSettlesStorage?.add(appeared: appeared, changed: changed, disappeared: disappeared)
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

    /// How many batches the lock barrier has refused a command of this session (B-146):
    /// what `build` reads to stop after a push that did not land, and a program driving the
    /// interpreter reads to tell a refused batch from any other failure.
    public private(set) var batchesRefused = 0

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
        try connect(subscribing: true)
    }

    /// Says hello, and subscribes to events only when `subscribing`. A client that leaves
    /// the reports to another one on the same engine — a `semel-watch` the prompt started,
    /// whose settles the prompt already prints from its own subscription — would otherwise
    /// print every summary twice into one terminal.
    public func connect(subscribing: Bool) throws -> (serverVersion: String, databasePath: String) {
        let (reply, _) = try connection.send(.hello(Hello(role: .daemon)), body: nil)
        guard case .hello(let helloResponse) = reply else {
            throw ConnectError.unexpectedReply
        }
        switch helloResponse {
        case .rejected(let reason):
            throw ConnectError.rejected(reason)
        case .accepted(let serverVersion, let databasePath):
            guard subscribing else {
                return (serverVersion, databasePath)
            }
            connection.onEvent = { [weak self] event in self?.printEvent(event) }
            _ = try request(.subscribe)
            return (serverVersion, databasePath)
        }
    }

    private func printEvent(_ event: Event) {
        switch event {
        case .daemon(.errors(let records)):
            if printsErrorEvents {
                ErrorReportRenderer.lines(for: records, style: ErrorReportStyle(colour: reportsInColour))
                    .forEach { outputMessage($0) }
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
            guard !holdArtifacts(appeared: appeared, changed: changed, disappeared: disappeared) else {
                return
            }
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
        handle { try run(command) }
    }

    /// Runs one command given as its words, as a program issues one: the verb and each
    /// argument already apart, so a path holding a space or a quote is one argument and
    /// no tokenizer reads it. What `semel-watch` drives the commands a person types with.
    @discardableResult
    public func handleCommand(verb: String, arguments: [String]) -> HandleCommandResult {
        handle { try run(tokens: [verb] + arguments) }
    }

    private func handle(_ body: () throws -> Void) -> HandleCommandResult {
        let errorsBefore = errorsReported
        do {
            try body()
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
        try run(tokens: tokenize(command))
    }

    private func run(tokens: [String]) throws {
        var tokens = tokens
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

        // `build <folder> [--into <dir>] [--no-follow] [--verbose]` is the whole loop in one
        // word: push the tree, wait for the graph to settle, push what the formula turned out
        // to need from the rest of the tree, report, and export the products — to `--into`, or
        // to `semel-out/<folder>` under the base. A macro over the commands rather than a
        // plugin, so each keeps its own meaning and its own tests.
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
            let verbose = arguments.contains("--verbose")
            arguments.removeAll { $0 == "--verbose" }
            guard arguments.count == 1 else {
                outputError("build: expected one folder to build")
                return
            }
            try build(folder: arguments[0], destination: destination, follows: follows, verbose: verbose)
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
            if case .batchRejected = error.response {
                batchesRefused += 1
            }
            outputError(error.description)
        } catch {
            outputError(Self.userFacingMessage(for: error))
        }
    }

    // MARK: - Driven by a program (B-126)

    /// Runs `body` as `build` runs its steps: the idle-time error reports and the settle
    /// summaries held while it runs, and printed at its end as one summary with the net
    /// artifact diff under it (`HeldSettles`). A program that pushes and then follows the
    /// formula's inputs would otherwise print a failing line for a source it is about to
    /// push. Counted either way, as during a build; the reports themselves are for an
    /// `errors` the caller runs after, as `build` runs one.
    public func holdingReports(_ body: () -> Void) {
        printsErrorEvents = false
        defer { printsErrorEvents = true }
        holdSettles()
        defer { _ = releaseSettles() }
        body()
        releaseSettles().forEach { outputMessage($0) }
    }

    /// `build`'s follow of the formula's inputs, on its own: pushes what the last settle
    /// reported missing and finds on disk under `base`, saying which formula in `folder`
    /// asked, and waits again, until a round finds nothing new. Returns the paths it
    /// pushed, relative to `base`, in path order. A failure is reported and counted, as a
    /// command's is.
    public func followSources(neededBy folder: String) -> [String] {
        var pushed: Set<String> = []
        _ = handle { pushed = try followSources(neededBy: folder, errorsBeforeSettle: errorsReported) }
        return pushed.sorted()
    }

    /// Keeps `path`, relative to `base`, out of every later push, as `build` keeps its
    /// export folder out: a program that exports into the tree it pushes would otherwise
    /// push its own products back in.
    public func excludeFromPush(_ path: String) {
        pushExclusions.insert(path)
    }

    /// Whether the input file system holds `path` — relative to its root, as `push` and
    /// `rm` take it — as something pushed: a file with its bytes, a folder pinned or not,
    /// and not a source already removed or a name the graph only asks for. What a program
    /// asks before an `rm`, so a file that came and went between two looks at the disk is
    /// not reported as a removal of nothing.
    public func inputHolds(_ path: String) throws -> Bool {
        let response: DaemonResponse
        do {
            response = try request(.list(fileSystem: .input, pattern: path)).0
        } catch let failure as ServerError where failure.isTheRequestsOwn {
            // A folder on the way that the graph does not hold is the listing's own
            // failure, and the answer is that the path is not held either.
            return false
        }
        guard case .list(let entries) = response else {
            return false
        }
        let asked = Path(path)
        return entries.contains { entry in
            Path(entry.path) == asked && Self.isHeld(entry)
        }
    }

    /// Every file and folder the input file system holds below `folder` — relative to its
    /// root, the empty string for the root itself — at any depth, dot-names among them, as
    /// `inputHolds` would answer for each: what a program mirroring a disk compares with
    /// the disk to learn what to remove. Gathered part by part as the listing streams, so
    /// a large tree's answer is never one frame. A folder the graph does not hold holds
    /// nothing.
    public func inputHoldings(below folder: String) throws -> [FileWildcardEntry] {
        let pattern = folder.isEmpty ? WildcardPath.anyFolders : "\(folder)/\(WildcardPath.anyFolders)"
        var entries: [ListEntry] = []
        let last: DaemonResponse
        do {
            last = try request(.list(fileSystem: .input, pattern: pattern)) { part in
                if case .list(let partEntries) = part {
                    entries.append(contentsOf: partEntries)
                }
            }.0
        } catch let failure as ServerError where failure.isTheRequestsOwn {
            return []
        }
        if case .list(let lastEntries) = last {
            entries.append(contentsOf: lastEntries)
        }
        return entries.filter(Self.isHeld).map { entry in
            FileWildcardEntry(path: Path(entry.path), kind: entry.kind == .folder ? .folder : .file,
                              state: .present, isUnreferenced: entry.status == .unreferenced)
        }
    }

    /// The locks the input file system holds at or below `folder` — relative to its root,
    /// the empty string for the root itself — each a file named `<name>.semel-lock` with
    /// its bytes, and the folder's own beside it: the paths of the locks, which name the
    /// folders they lock (B-146). One listing for the tree, by the lock's own pattern.
    public func inputLocks(below folder: String) throws -> [String] {
        let suffix  = "*.\(DependencyLock.fileExtension)"
        let pattern = folder.isEmpty ? "\(WildcardPath.anyFolders)/\(suffix)" : "\(folder)/\(WildcardPath.anyFolders)/\(suffix)"
        var entries: [ListEntry] = []
        let last: DaemonResponse
        do {
            last = try request(.list(fileSystem: .input, pattern: pattern)) { part in
                if case .list(let partEntries) = part {
                    entries.append(contentsOf: partEntries)
                }
            }.0
        } catch let failure as ServerError where failure.isTheRequestsOwn {
            return []
        }
        if case .list(let lastEntries) = last {
            entries.append(contentsOf: lastEntries)
        }
        var locks = entries.filter { $0.kind == .file && Self.isHeld($0) }.map(\.path)
        if !folder.isEmpty {
            let ownLock = DependencyLock.lockPath(forDependencyAt: folder)
            if try inputHolds(ownLock) {
                locks.append(ownLock)
            }
        }
        return locks.sorted()
    }

    /// Whether a listed name stands for something pushed: there, read or not — not a
    /// source removed and still standing, nor a name the graph only asks for.
    private static func isHeld(_ entry: ListEntry) -> Bool {
        entry.status == .none || entry.status == .unreferenced
    }

    /// Whether the graph holds any failure, as `errors` would list it, without printing
    /// it. What decides an export after a settle: the settle's own event names only what
    /// newly failed, and a failure that stands from an earlier one leaves the products as
    /// broken as a new one does.
    public func graphHasErrors() throws -> Bool {
        !(try errorRecords().isEmpty)
    }

    /// Every failure the graph holds, as `errors` would list it, without printing it.
    public func errorRecords() throws -> [ErrorRecord] {
        guard case .errors(let records) = try request(.errors(product: nil)).0 else {
            return []
        }
        return records
    }

    // MARK: - build

    /// The `build` macro's steps. The report is printed once, at the end: the settles the
    /// follow loop answers by pushing what they named are held, and the one that stands is
    /// the verdict.
    private func build(folder: String, destination: String?, follows: Bool, verbose: Bool) throws {
        let errorsBefore = errorsReported
        printsErrorEvents = false
        defer { printsErrorEvents = true }
        holdSettles()
        defer { _ = releaseSettles() }
        let refusedBefore = batchesRefused
        try run("push \(folder)")
        // A refused push changed nothing, so there is nothing to wait for, and what the
        // last build exported is still what `input:` builds.
        guard batchesRefused == refusedBefore else {
            outputMessage("Not built: the push was refused, and nothing was exported.")
            return
        }
        let errorsBeforeSettle = errorsReported
        try run("wait")
        if follows {
            _ = try followSources(neededBy: folder, errorsBeforeSettle: errorsBeforeSettle)
        }
        // After the last `Settled.`, which says only that the waiting is over: this is
        // what the build did, read with the report under it.
        releaseSettles().forEach { outputMessage($0) }

        let exportFolder = destination
            ?? (baseDirectory as NSString).appendingPathComponent("\(Self.defaultExportFolder)/\(folder)")
        // A destination inside the tree is a folder a later push must leave alone, as
        // the default one is.
        if let inTree = Self.relativePath(of: exportFolder, under: baseDirectory) {
            pushExclusions.insert(inTree)
        }

        let records = try errorRecords()
        // Counted as the `errors` verb counts a report: the exit status is what says the
        // build failed, whatever was exported.
        countErrorRecords(records)
        guard !records.isEmpty else {
            // A command that failed on the way — a push of a folder that is not there — is
            // its own report, above; nothing is exported over it.
            guard errorsReported == errorsBefore else {
                return
            }
            outputMessage("No errors.")
            // A named destination with nothing to put in it is `export`'s error to report;
            // the default one is only used when there is something to put in it.
            if try destination != nil || hasProducts(folder) {
                try run("export \(folder) --into \(exportFolder)")
            } else {
                outputMessage("Nothing to export: the build published no products.")
            }
            return
        }

        let style = ErrorReportStyle(verbose: verbose, colour: reportsInColour)
        let export = try exportBeside(records: records, folders: [folder], destination: exportFolder,
                                      exportsWhatHasAValue: destination != nil)
        reportErrors(records, style: style, export: export, printsBlocks: true)
        if let hint = prepareHint(for: folder) {
            outputMessage(hint)
        }
    }

    // MARK: - The report a build ends with

    /// The report of a graph holding errors, as a build or a watcher's batch ends with it:
    /// the blocks — unless `printsBlocks` is off, for a watcher whose prompt prints its own
    /// report — then the summary line, which says what became of the export. Counted by
    /// the caller.
    public func reportErrors(_ records: [ErrorRecord], style: ErrorReportStyle, export: ExportOutcome?, printsBlocks: Bool) {
        let lines = ErrorReportRenderer.lines(for: records, style: style, export: export)
        (printsBlocks ? lines : Array(lines.suffix(1))).forEach { outputMessage($0) }
    }

    /// The export a graph holding errors allows, made, and what it came to.
    ///
    /// Every product with a value: the errors reach no product — a settings source read as
    /// nothing to add — so the products are the whole set, and they are exported as a clean
    /// build exports them. Otherwise nothing, unless `exportsWhatHasAValue`: a destination
    /// the reader named with `--into` gets the products that have a value, and the summary
    /// says how many of how many. A partial set in the default folder beside the sources
    /// would only mislead; a folder the reader named is one they asked to have filled.
    public func exportBeside(records: [ErrorRecord], folders: [String], destination: String,
                             exportsWhatHasAValue: Bool) throws -> ExportOutcome {
        let withoutValue = ErrorReportRenderer.productsWithoutValue(records).filter { product in
            folders.contains { folder in Self.isProduct(product, under: folder) }
        }
        guard withoutValue.isEmpty || exportsWhatHasAValue else {
            return .nothing
        }
        var exported = 0
        // A folder that published nothing has nothing to export, which is no error here:
        // the report above is what the reader has to act on.
        for folder in folders where try folder == "." || hasProducts(folder) {
            exported += try FilePlugin.exportFiles(folderToken: folder, destination: destination,
                                                   skippingWithoutValue: true, context: self) ?? 0
        }
        guard withoutValue.isEmpty else {
            return .partial(exported: exported, of: exported + withoutValue.count)
        }
        return exported == 0 ? .nothing : .whole(destination: displayedDestination(destination))
    }

    /// Whether a product's path, `output:/hello/hello`, lies under a built folder — `.`
    /// being every product.
    static func isProduct(_ product: String, under folder: String) -> Bool {
        let root = Path(FileSystemName.output)
        let normalized = Path(folder).segments.filter { $0 != "." }
        let prefix = normalized.isEmpty ? root.string : (root / Path(normalized.joined(separator: "/"))).string
        return product == prefix || product.hasPrefix(prefix + "/")
    }

    /// A destination as the summary line names it: relative to the base when it lies under
    /// it, as `semel-out/hello`; as given otherwise.
    func displayedDestination(_ destination: String) -> String {
        Self.relativePath(of: ExternalPathSanitizer.expandPartialPath(destination), under: baseDirectory) ?? destination
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
            HelpEntry(verbs: ["build"], usage: "build <folder> [--into <dir>] [--no-follow] [--verbose]",
                      description: "push the folder, wait, report; push what its formula needs from the tree; "
                                 + "export the products, to semel-out/<folder> under the base unless --into says where; "
                                 + "with errors, --into still gets what has a value"),
            HelpEntry(verbs: ["wait"], usage: "wait",
                      description: "block until the build has settled; at a terminal a line shows where it stands, "
                                 + "and SEMEL_PROGRESS=full lists the running nodes under it"),
            HelpEntry(verbs: ["watch"], usage: "watch",
                      description: "show where the settle stands until a key is pressed or the settle ends; "
                                 + "a key leaves it running and says where it stood"),
            HelpEntry(verbs: ["watch"],
                      usage: "watch <folder> [--into <dir>] [--only <pattern>] [--except <pattern>] [--verbose]",
                      description: "start a semel-watch that pushes the folder as you save, after two quiet seconds; "
                                 + "--into exports what has a value after each settle; one per session"),
            HelpEntry(verbs: ["unwatch"], usage: "unwatch", description: "stop the semel-watch `watch <folder>` started"),
            HelpEntry(verbs: ["errors", "e"], usage: "errors [<product>] [--verbose]",
                      description: "what has no value and why: each cause once, with the products that need it; "
                                 + "with a product, or a tree product's folder, the causes it has no value because of; "
                                 + "--verbose adds the engine's facts"),
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
            HelpEntry(verbs: ["push"], usage: "push <path> ...",
                      description: "send files or folders under the base into the input file system; a push that "
                                 + "changes a locked folder without its lock is refused whole (see commit)"),
            HelpEntry(verbs: ["rm", "remove"], usage: "rm <path> ...", description: "remove pushed files or folders"),
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
            HelpEntry(verbs: ["base"], usage: "base [<path> | --forget]",
                      description: "show or set the tree pushes are read from, remembered for the next launch; "
                                 + "--forget stops remembering it, and semel then starts in the current directory"),
            HelpEntry(verbs: ["begin", "commit"], usage: "begin … commit",
                      description: "hold the engine across several pushes, so it settles once; commit refuses the whole "
                                 + "batch, and puts input: back, when it changed a folder locked by a <folder>.semel-lock "
                                 + "beside it without a lock the folder then matches"),
            HelpEntry(verbs: ["checkpoint"], usage: "checkpoint [<name>]",
                      description: "name the tree input: holds, `latest` unless a name is given; a checkpoint is a "
                                 + "value, the tree's content root, not a moment"),
            HelpEntry(verbs: ["checkpoints"], usage: "checkpoints", description: "every checkpoint, by name, with its root"),
            HelpEntry(verbs: ["restore"], usage: "restore <name>",
                      description: "make input: the checkpoint's tree again, in one batch through the locks; "
                                 + "the settle it causes is answered from the cache"),
            HelpEntry(verbs: ["quit", "q", "exit"], usage: "quit", description: "leave the prompt, stopping its watcher"),
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
    ///
    /// Returns the paths it pushed, relative to `base`.
    private func followSources(neededBy folder: String, errorsBeforeSettle: Int) throws -> Set<String> {
        var pushed: Set<String> = []
        var errorsBeforeSettle = errorsBeforeSettle
        while true {
            guard case .errors(let records) = try request(.errors(product: nil)).0 else {
                return pushed
            }
            let missing = records.flatMap { $0.document.causes.compactMap(\.unpushedSource) }
            let onDisk = missing.filter { path in
                !pushed.contains(path)
                    && FileManager.default.fileExists(atPath: (baseDirectory as NSString).appendingPathComponent(path))
            }
            guard !onDisk.isEmpty else {
                return pushed
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
        // `.` is the base itself, so a folder of `.` climbs nothing.
        let target = Path(path).segments
        let origin = Path(folder).segments.filter { $0 != "." }
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
