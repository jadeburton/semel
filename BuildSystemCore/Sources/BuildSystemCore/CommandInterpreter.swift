// CommandInterpreter.swift
// build_system

import Foundation

enum CommandInterpreterError: Error {
    case quit
}

final class CommandInterpreter: CommandContext {

    let commandParser = CommandParser()
    let database: DatabaseLayer

    var baseDirectory: String?
    var currentFileSystem: FileSystemForCommand = .input
    var currentDirectoryPath: Path = .empty

    var buildEngine: BuildEngine { BuildEngine.shared }
    var inputFileSystem: Node    { get throws { try buildEngine.inputFileSystem } }
    var outputFileSystem: Node   { get throws { try buildEngine.outputFileSystem } }

    func outputMessage(_ message: String) { print(message) }
    func outputError(_ errorMessage: String) { print(errorMessage) }

    private let plugins: [any CommandPlugin] = [
        NavigationPlugin(),
        FilePlugin(),
        EnginePlugin(),
        SessionPlugin(),
    ]

    required init(database: DatabaseLayer) {
        self.database = database
        try? SessionPlugin().handle(.base(externalPath: "/Users/jadeburton/build_system/C1/C1"), context: self)
    }

    func handleCommand(_ command: String) throws {
        do {
            try handleUserCommand(commandParser.parse(command: command))
        } catch CommandInterpreterError.quit {
            throw CommandInterpreterError.quit
        } catch let error as NodeError {
            outputError("\(error)")
        } catch {
            outputError(error.localizedDescription)
        }
    }

    func handleUserCommand(_ userCommand: UserCommand) throws {
        for plugin in plugins {
            if try plugin.handle(userCommand, context: self) { return }
        }
    }
}
