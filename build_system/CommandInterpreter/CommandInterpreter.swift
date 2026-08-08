// CommandInterpreter.swift
// build_system

import Foundation
import BuildSystemCore

enum CommandInterpreterError: Error {
    case quit
}

final class CommandInterpreter: CommandContext {

    let database: DatabaseLayer
    var baseDirectory: String
    var currentFileSystem: FileSystemForCommand = .input
    var currentDirectoryPath: Path = .empty

    var buildEngine: BuildEngine  { BuildEngine.shared }
    var inputFileSystem: Node     { get throws { try buildEngine.inputFileSystem } }
    var outputFileSystem: Node    { get throws { try buildEngine.outputFileSystem } }

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

    required init(database: DatabaseLayer,
                  baseDirectory: String = FileManager.default.currentDirectoryPath,
                  plugins: [any CommandPlugin] = [NavigationPlugin(),
                                                  FilePlugin(),
                                                  EnginePlugin(),
                                                  SessionPlugin()]) {

        self.plugins = plugins
        self.baseDirectory = baseDirectory
        self.database = database
    }

    func handleCommand(_ command: String) throws {
        var tokens = tokenize(command)
        guard !tokens.isEmpty else { return }
        if tokens.first == "strato" { tokens.removeFirst() }
        guard let verb = tokens.first else { return }
        let remaining = Array(tokens.dropFirst())

        do {
            guard let plugin = verbMap[verb] else {
                throw CommandParserError.unknownCommand(verb)
            }
            try plugin.handle(verb: verb, tokens: remaining, context: self)
        } catch CommandInterpreterError.quit {
            throw CommandInterpreterError.quit
        } catch let error as NodeError {
            outputError("\(error)")
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
