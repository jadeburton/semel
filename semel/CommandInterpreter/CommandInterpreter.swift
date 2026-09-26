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

    func outputMessage(_ message: String) { output(message) }
    func outputError(_ errorMessage: String) {
        errorsLock.withLock { errorsReportedStorage += 1 }
        output(errorMessage)
    }

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

    public convenience init(connection: any SemelConnection,
                            baseDirectory: String = FileManager.default.currentDirectoryPath) {
        self.init(connection: connection,
                  baseDirectory: baseDirectory,
                  plugins: [NavigationPlugin(), FilePlugin(), EnginePlugin(), SessionPlugin()])
    }

    required init(connection: any SemelConnection,
                  baseDirectory: String,
                  plugins: [any CommandPlugin]) {
        self.connection    = connection
        self.baseDirectory = baseDirectory
        self.plugins       = plugins
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
            try run("push \(folder)")
            let errorsBeforeSettle = errorsReported
            try run("wait")
            if follows {
                try followSources(neededBy: folder, errorsBeforeSettle: errorsBeforeSettle)
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
                throw CommandParserError.unknownCommand(verb)
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
    case unknownCommand(String)
    case missingArgument(command: String, expected: String)
    case tooManyArguments(command: String)
    case unknownOption(command: String, option: String)

    var errorDescription: String? {
        switch self {
        case .unknownCommand(let cmd):
            return "Unknown command: \(cmd)"
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
