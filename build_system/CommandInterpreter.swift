//
//  CommandInterpreter.swift
//  build_system
//
//  Created by Jade Burton on 22.02.26.
//

import Foundation

enum FileWildcardEntryKind {
    case file
    case folder
}

struct FileWildcardEntry {
    let path: String
    let kind: FileWildcardEntryKind
}

protocol FileWildcardMatcherInput {
    var rootDirectoryPath: String { get }

    func allFiles(inDirectoryPath: String) -> [FileWildcardEntry]
}

final class FileWildcardMatcher {
    private let input: FileWildcardMatcherInput

    init(input: FileWildcardMatcherInput) {
        self.input = input
    }

    // Supports ? for single character, * for partial match, and ** for recursive match.
    func findAllMatching(pathOrWildcard: String) -> [FileWildcardEntry] {
        []
    }
}

final class ExternalFileSystemLister: FileWildcardMatcherInput {
    let rootDirectoryPath: String

    init(rootDirectoryPath: String) {
        self.rootDirectoryPath = rootDirectoryPath
    }

    func allFiles(inDirectoryPath: String) -> [FileWildcardEntry] {
        []
    }
}

final class InternalFileSystemLister: FileWildcardMatcherInput {
    let rootDirectoryPath = "/"
    let fileSystem: FileSystem

    init(fileSystem: FileSystem) {
        self.fileSystem = fileSystem
    }

    func allFiles(inDirectoryPath: String) -> [FileWildcardEntry] {
        []
    }
}

enum FileSystemForCommand {
    case input
    case output
}

enum UserCommand {
    case base(externalPath: String) // strato base .
    case begin           // strato begin
    case commit          // strato commit
    case discard         // strato discard
    case push(externalPathOrWildcard: String) // strato push Example/src/myfile.c
    case remove(pathOrWildcard: String) // strato rm /**/*.*
    case copy(fileSystem: FileSystemForCommand, pathOrWildcard: String, destinationPath: String)   // strato cp [-i] /Example/src/myfile.c .
    case list(fileSystem: FileSystemForCommand, pathOrWildcard: String) // strato ls [-i] /Example/**/*.c
}

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

final class CommandParser {

    /// Parse a command string into a UserCommand.
    ///
    /// Supported syntax (the leading "strato" prefix is optional):
    /// ```
    /// base <externalPath>
    /// begin
    /// commit
    /// discard
    /// push <pathOrWildcard>
    /// rm <pathOrWildcard>
    /// cp [-i|-o] <pathOrWildcard> <destinationPath>
    /// ls [-i|-o] <pathOrWildcard>
    /// ```
    func parse(command: String) throws -> UserCommand {
        var tokens = tokenize(command)

        guard !tokens.isEmpty else {
            throw CommandParserError.emptyCommand
        }

        // Strip optional "strato" prefix
        if tokens.first == "strato" {
            tokens.removeFirst()
        }

        guard let verb = tokens.first else {
            throw CommandParserError.emptyCommand
        }
        tokens.removeFirst()

        switch verb {

        case "base":
            guard let path = tokens.first else {
                throw CommandParserError.missingArgument(command: "base", expected: "externalPath")
            }
            return .base(externalPath: path)

        case "begin":
            return .begin

        case "commit":
            return .commit

        case "discard":
            return .discard

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
            let (fileSystem, remaining) = parseFileSystemFlag(tokens: tokens)
            guard remaining.count >= 2 else {
                throw CommandParserError.missingArgument(command: "cp", expected: "pathOrWildcard destinationPath")
            }
            return .copy(fileSystem: fileSystem, pathOrWildcard: remaining[0], destinationPath: remaining[1])

        case "ls", "list":
            let (fileSystem, remaining) = parseFileSystemFlag(tokens: tokens)
            guard let path = remaining.first else {
                throw CommandParserError.missingArgument(command: "ls", expected: "pathOrWildcard")
            }
            return .list(fileSystem: fileSystem, pathOrWildcard: path)

        default:
            throw CommandParserError.unknownCommand(verb)
        }
    }

    // MARK: - Private helpers

    /// Split a command string into tokens, respecting double-quoted strings.
    private func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false

        for char in command {
            if char == "\"" {
                inQuotes.toggle()
            } else if char.isWhitespace && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    /// Parse an optional `-i` (input) or `-o` (output) flag from the front of the token list.
    /// Defaults to `.input` when no flag is present.
    private func parseFileSystemFlag(tokens: [String]) -> (FileSystemForCommand, [String]) {
        guard let first = tokens.first else {
            return (.input, tokens)
        }

        switch first {
        case "-i", "--input":
            return (.input, Array(tokens.dropFirst()))
        case "-o", "--output":
            return (.output, Array(tokens.dropFirst()))
        default:
            return (.input, tokens)
        }
    }
}

final class CommandInterpreter: NodeType {
    static let kind: UInt = 0

    let commandParser = CommandParser()

    var nodeContext: NodeContext!

    var baseDirectory: String?

    enum CodingKeys: String, CodingKey {
        case baseDirectory
    }

    required init() {
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseDirectory = try container.decodeIfPresent(String.self, forKey: .baseDirectory)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseDirectory, forKey: .baseDirectory)
    }

    var descriptor: NodeKindDescriptor {
        .init(kind: Self.kind, inputs: [], outputs: [])
    }

    func outputMessage(_ message: String) {
        print(message)
    }

    func outputError(_ errorMessage: String) {
        print(errorMessage)
    }

    func handleCommand(_ command: String) throws {
        do {
            try handleUserCommand(commandParser.parse(command: command))
        } catch {
            outputError(error.localizedDescription)
        }
    }

    func handleUserCommand(_ userCommand: UserCommand) throws {
        switch userCommand {

        case .base(let externalPath):
            handleBase(externalPath: externalPath)

        case .begin:
            handleBegin()

        case .commit:
            handleCommit()

        case .discard:
            handleDiscard()

        case .push(let externalPathOrWildcard):
            handlePush(externalPathOrWildcard: externalPathOrWildcard)

        case .remove(let pathOrWildcard):
            handleRemove(pathOrWildcard: pathOrWildcard)

        case .copy(let fileSystem, let pathOrWildcard, let destinationPath):
            handleCopy(fileSystem: fileSystem, pathOrWildcard: pathOrWildcard, destinationPath: destinationPath)

        case .list(let fileSystem, let pathOrWildcard):
            handleList(fileSystem: fileSystem, pathOrWildcard: pathOrWildcard)

        }
    }

    private func handleBase(externalPath: String) {
        baseDirectory = externalPath
    }

    private func handleBegin() {
        // Coming soon
    }

    private func handleCommit() {
        // Coming soon
    }

    private func handleDiscard() {
        // Coming soon
    }

    lazy var inputFileSystem: FileSystem = {
        try! nodeContext.buildEngine.loadOrCreateSingletonNode(kind: FileSystem.kind, name: "inputFileSystem") as FileSystem
    }()

    lazy var outputFileSystem: FileSystem = {
        try! nodeContext.buildEngine.loadOrCreateSingletonNode(kind: FileSystem.kind, name: "outputFileSystem") as FileSystem
    }()

    func pushOne(_ entry: FileWildcardEntry) {
        guard let baseDirectory else {
            outputError("Set a base directory before pushing files")
            return
        }

        switch entry.kind {

        case .file:
/*            inputFileSystem.ensureEntirePathExists(entry.path.deletingLastPathComponent)

            // locate the file in the external file system
            // read the file
            let fileContent = try! Data(contentsOf: URL(fileURLWithPath: entry.path)).bytes

            let path = entry.path.withoutBaseDirectory(baseDirectory)

            // if it does not already exist, synchronously create a new Node representing this file in the internal file system

            // if it does already exist, write to its input port with the file content, which should cause it to emit mutation events if the content has changed
            // creating a new Node will cause its parent folder to emit mutation events, and its parent, all the way to the root folder
            // mutation events will be queued on other Nodes that are subscribed
            inputFileSystem.addOrReplaceFile(path: path, content: fileContent)
*/
            break

        case .folder:
            //inputFileSystem.ensureEntirePathExists(entry.path)
            break
        }

    }

    private func handlePush(externalPathOrWildcard: String) {
        guard let baseDirectory else {
            outputError("Set a base directory before pushing files")
            return
        }

        let matcher = FileWildcardMatcher(input: ExternalFileSystemLister(rootDirectoryPath: baseDirectory))

        matcher.findAllMatching(pathOrWildcard: externalPathOrWildcard).forEach { entry in
            pushOne(entry)
        }
    }

    private func handleRemove(pathOrWildcard: String) {
        let matcher = FileWildcardMatcher(input: InternalFileSystemLister(fileSystem: inputFileSystem))

        matcher.findAllMatching(pathOrWildcard: pathOrWildcard).forEach { entry in
            removeOne(entry)
        }
        // locate the file or folder in the internal file system
        // if it does not exist, report error to user
        // if it is a folder, recursively remove all files and folders inside
        // remove the Node representing this file or folder from the internal file system
        // deleting a Node will cause its parent folder to emit mutation events, and its parent, all the way to the root folder
        // deleting a Node that has Wires will cause wire-removed events for wire targets
        // mutation events will be queued on other Nodes that are subscribed
    }

    private func removeOne(_ entry: FileWildcardEntry) {
    }

    private func handleCopy(fileSystem: FileSystemForCommand, pathOrWildcard: String, destinationPath: String) {
        func handle(fileSystem: FileSystem) {
            let matcher = FileWildcardMatcher(input: InternalFileSystemLister(fileSystem: fileSystem))

            matcher.findAllMatching(pathOrWildcard: pathOrWildcard).forEach { entry in
                copyOneFile(fileSystem: fileSystem, entry: entry, destinationPath: destinationPath)
            }
        }

        switch fileSystem {
        case .input:
            handle(fileSystem: inputFileSystem)
        case .output:
            handle(fileSystem: outputFileSystem)
        }
    }

    private func copyOneFile(fileSystem: FileSystem, entry: FileWildcardEntry, destinationPath: String) {

    }

    private func handleList(fileSystem: FileSystemForCommand, pathOrWildcard: String) {
        let matcher = FileWildcardMatcher(input: InternalFileSystemLister(fileSystem: inputFileSystem))

        matcher.findAllMatching(pathOrWildcard: pathOrWildcard).forEach { entry in
            outputMessage(entry.path)
        }
    }

    func processInputs(_ inputs: [NodeKindDescriptor.InputPort: [NodeInputMessage]?]) throws -> [NodeKindDescriptor.OutputPort: NodeProcessPortOutput?] {
        [:]
    }
}
