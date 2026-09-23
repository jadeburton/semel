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
    var currentFileSystem: FileSystemForCommand = .input
    var currentDirectoryPath: Path = .empty

    func outputMessage(_ message: String) { print(message) }
    func outputError(_ errorMessage: String) {
        errorsLock.withLock { errorsReportedStorage += 1 }
        print(errorMessage)
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
            records.flatMap(ErrorRecordRenderer.lines(for:)).forEach { outputMessage($0) }
            countErrorRecords(records)
        case .daemon(.notice(let line)):
            outputMessage(line)
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

        // `build <folder> [--into <dir>]` is the whole loop in one word: push the tree,
        // wait for the graph to settle, report, and — given a destination — export the
        // products. A macro over the commands rather than a plugin, so each keeps its own
        // meaning and its own tests. The destination is the opt-in; there is nothing to
        // default. No export after a build that reported errors: the exit status already
        // says it failed, and a partial product set beside it would only mislead.
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
            guard arguments.count == 1 else {
                outputError("build: expected one folder to build")
                return
            }
            let errorsBefore = errorsReported
            try run("push \(arguments[0])")
            try run("wait")
            try run("errors")
            if let destination, errorsReported == errorsBefore {
                try run("export \(arguments[0]) --into \(destination)")
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
