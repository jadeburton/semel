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
    func outputError(_ errorMessage: String) { print(errorMessage) }

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
    /// needs. Events arrive on the connection's thread, which is where the engine used to
    /// print from when it shared a process with the REPL.
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
        case .daemon(.notice(let line)):
            outputMessage(line)
        }
    }

    // MARK: - Commands

    public func handleCommand(_ command: String) throws {
        var tokens = tokenize(command)
        guard !tokens.isEmpty else {
            return
        }
        if tokens.first == "semel" { tokens.removeFirst() }
        guard let verb = tokens.first else {
            return
        }
        let remaining = Array(tokens.dropFirst())

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
            outputError(error.localizedDescription)
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

    var errorDescription: String? {
        switch self {
        case .unknownCommand(let cmd):
            return "Unknown command: \(cmd)"
        case .missingArgument(let cmd, let expected):
            return "\(cmd): missing argument (\(expected))"
        case .tooManyArguments(let cmd):
            return "\(cmd): too many arguments"
        }
    }
}
