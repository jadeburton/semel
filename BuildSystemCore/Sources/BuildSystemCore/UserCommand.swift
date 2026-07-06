// UserCommand.swift
// build_system

import Foundation

enum FileSystemForCommand {
    case input
    case output
}

enum UserCommand {
    case base(externalPath: String)
    case debug
    case nudge
    case quit
    case begin
    case commit
    case discard
    case push(externalPathOrWildcard: String)
    case remove(pathOrWildcard: String)
    case copy(folder: FileSystemForCommand, pathOrWildcard: String, destinationPath: String?)
    case list(folder: FileSystemForCommand, pathOrWildcard: String)
    case errors
}

// MARK: - CommandParserError

enum CommandParserError: Error, LocalizedError {
    case emptyCommand
    case unknownCommand(String)
    case missingArgument(command: String, expected: String)
    case tooManyArguments(command: String)

    var errorDescription: String? {
        switch self {
        case .emptyCommand:
            return "Empty command"
        case .unknownCommand(let cmd):
            return "Unknown command: \(cmd)"
        case .missingArgument(let cmd, let expected):
            return "\(cmd): missing argument (\(expected))"
        case .tooManyArguments(let cmd):
            return "\(cmd): too many arguments"
        }
    }
}

// MARK: - CommandParser

final class CommandParser {

    /// Parse a command string into a `UserCommand`.
    ///
    /// The leading `strato` prefix is optional. Supported verbs:
    /// ```
    /// base <externalPath>
    /// begin | commit | discard
    /// push <pathOrWildcard>
    /// rm <pathOrWildcard>
    /// cp [-i|-o] <pathOrWildcard> [destinationPath]
    /// ls [-i|-o] [pathOrWildcard]
    /// errors
    /// debug | nudge | quit
    /// ```
    func parse(command: String) throws -> UserCommand {
        var tokens = tokenize(command)

        guard !tokens.isEmpty else { throw CommandParserError.emptyCommand }

        if tokens.first == "strato" { tokens.removeFirst() }

        guard let verb = tokens.first else { throw CommandParserError.emptyCommand }
        tokens.removeFirst()

        switch verb {

        case "base":
            guard let path = tokens.first else {
                throw CommandParserError.missingArgument(command: "base", expected: "externalPath")
            }
            return .base(externalPath: path)

        case "d", "debug":   return .debug
        case "n", "nudge":   return .nudge
        case "q", "quit", "exit": return .quit
        case "begin":        return .begin
        case "commit":       return .commit
        case "discard":      return .discard

        case "push":
            guard let path = tokens.first else {
                throw CommandParserError.missingArgument(command: "push", expected: "pathOrWildcard")
            }
            return .push(externalPathOrWildcard: path)

        case "rm", "remove":
            guard let path = tokens.first else {
                throw CommandParserError.missingArgument(command: "rm", expected: "pathOrWildcard")
            }
            return .remove(pathOrWildcard: path)

        case "cp", "copy":
            let (folder, remaining) = parseFileSystemFlag(tokens: tokens)
            guard remaining.count >= 1 else {
                throw CommandParserError.missingArgument(command: "cp",
                                                         expected: "pathOrWildcard [destinationPath]")
            }
            return .copy(folder: folder,
                         pathOrWildcard: remaining[0],
                         destinationPath: remaining.count >= 2 ? remaining[1] : nil)

        case "ls", "list":
            let (folder, remaining) = parseFileSystemFlag(tokens: tokens)
            return .list(folder: folder, pathOrWildcard: remaining.first ?? "*")

        case "errors":
            return .errors

        default:
            throw CommandParserError.unknownCommand(verb)
        }
    }

    // MARK: - Private helpers

    /// Split on whitespace, preserving double-quoted strings as single tokens.
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

    /// Consume an optional `-i`/`-o` flag from the front of the token list.
    /// Defaults to `.input` when absent.
    private func parseFileSystemFlag(tokens: [String]) -> (FileSystemForCommand, [String]) {
        guard let first = tokens.first else { return (.input, tokens) }
        switch first {
        case "-i", "--input":  return (.input,  Array(tokens.dropFirst()))
        case "-o", "--output": return (.output, Array(tokens.dropFirst()))
        default:               return (.input,  tokens)
        }
    }
}
