// CommandInterpreter.swift
// semel

import Foundation
import SemelCore
import SemelNodeKit

enum CommandInterpreterError: Error {
    case quit
}

public final class CommandInterpreter: CommandContext {

    let database: DatabaseLayer
    var baseDirectory: String
    var currentFileSystem: FileSystemForCommand = .input
    var currentDirectoryPath: Path = .empty

    let buildEngine: BuildEngine
    var inputFileSystem: NodeRecord     { get throws { try buildEngine.inputFileSystem } }
    var outputFileSystem: NodeRecord    { get throws { try buildEngine.outputFileSystem } }

    func outputMessage(_ message: String) { print(message) }
    func outputError(_ errorMessage: String) {
        errorsReported += 1
        print(errorMessage)
    }

    /// How many errors commands have reported so far. A non-interactive run exits non-zero
    /// when this is not zero, which is what makes `semel 'build Packages'` a build step.
    public private(set) var errorsReported = 0

    private let plugins: [any CommandPlugin]

    private lazy var verbMap: [String: any CommandPlugin] = {
        var map: [String: any CommandPlugin] = [:]
        for plugin in plugins {
            for verb in plugin.verbs { map[verb] = plugin }
        }
        return map
    }()

    /// No default for `buildEngine`: the one place that resolves the process-wide engine
    /// should be the composition root in main.swift, not a default argument here.
    public convenience init(database: DatabaseLayer,
                            buildEngine: BuildEngine,
                            baseDirectory: String = FileManager.default.currentDirectoryPath) {
        self.init(database: database,
                  buildEngine: buildEngine,
                  baseDirectory: baseDirectory,
                  plugins: [NavigationPlugin(), FilePlugin(), EnginePlugin(), SessionPlugin()])
    }

    required init(database: DatabaseLayer,
                  buildEngine: BuildEngine,
                  baseDirectory: String,
                  plugins: [any CommandPlugin]) {

        self.database = database
        self.buildEngine = buildEngine
        self.baseDirectory = baseDirectory
        self.plugins = plugins
    }

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
            try handleCommand("push \(arguments[0])")
            try handleCommand("wait")
            try handleCommand("errors")
            if let destination, errorsReported == errorsBefore {
                try handleCommand("export \(arguments[0]) --into \(destination)")
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
        } catch let error as NodeError {
            outputError("\(error)")
        } catch {
            // A command that failed because the store or database is unusable is not a
            // command error — reporting it as one invites the user to try again.
            FatalErrors.check(error)
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
