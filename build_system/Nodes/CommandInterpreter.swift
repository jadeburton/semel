//
//  CommandInterpreter.swift
//  build_system
//
//  Created by Jade Burton on 22.02.26.
//

import Foundation

private extension String {
    /// Returns the portion of this path after the given base directory.
    /// e.g. "/Users/jade/project/src/main.c".relativeTo("/Users/jade/project") → "src/main.c"
    func relativeTo(_ baseDirectory: String) -> String {
        let base = baseDirectory.hasSuffix("/") ? baseDirectory : baseDirectory + "/"
        if self.hasPrefix(base) {
            return String(self.dropFirst(base.count))
        }
        return self
    }
}

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

    /// Find all files and folders matching a glob pattern.
    ///
    /// Supports:
    /// - `?`  — matches any single character
    /// - `*`  — matches zero or more characters within a single path segment
    /// - `**` — matches zero or more directory levels (recursive)
    ///
    /// Examples:
    /// - `/Example/src/myfile.c`  — exact path
    /// - `/Example/**/*.c`        — all `.c` files recursively under `/Example`
    /// - `/**/*.*`                — all files with an extension, recursively
    func findAllMatching(pathOrWildcard: String) -> [FileWildcardEntry] {
        let normalised = pathOrWildcard.hasPrefix("/")
            ? pathOrWildcard
            : "/" + pathOrWildcard

        let segments = normalised
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        var results: [FileWildcardEntry] = []
        matchSegments(
            segments: segments,
            segmentIndex: 0,
            currentDirectory: input.rootDirectoryPath,
            currentLogicalPath: input.rootDirectoryPath,
            results: &results
        )
        return results
    }

    // MARK: - Private recursive matcher

    /// Recursively walk the directory tree, consuming pattern segments as they
    /// match entries returned by `input.allFiles(inDirectoryPath:)`.
    private func matchSegments(
        segments: [String],
        segmentIndex: Int,
        currentDirectory: String,
        currentLogicalPath: String,
        results: inout [FileWildcardEntry]
    ) {
        // All segments consumed — nothing more to match.
        guard segmentIndex < segments.count else { return }

        let segment = segments[segmentIndex]
        let isLastSegment = segmentIndex == segments.count - 1

        // ── ** (double-star / globstar) ──────────────────────────────
        if segment == "**" {
            // ** can match zero directories (skip it) …
            matchSegments(
                segments: segments,
                segmentIndex: segmentIndex + 1,
                currentDirectory: currentDirectory,
                currentLogicalPath: currentLogicalPath,
                results: &results
            )

            // … or match one-or-more directories (recurse into each child dir).
            let children = input.allFiles(inDirectoryPath: currentDirectory)
            for child in children {
                let childLogicalPath = (currentLogicalPath as NSString).appendingPathComponent(child.path)

                if child.kind == .folder {
                    let childPhysicalPath = (currentDirectory as NSString).appendingPathComponent(child.path)

                    // Keep consuming ** in this subfolder.
                    matchSegments(
                        segments: segments,
                        segmentIndex: segmentIndex,
                        currentDirectory: childPhysicalPath,
                        currentLogicalPath: childLogicalPath,
                        results: &results
                    )
                }
            }
            return
        }

        // ── Normal or single-star segment ────────────────────────────
        let children = input.allFiles(inDirectoryPath: currentDirectory)

        for child in children {
            guard segmentMatches(pattern: segment, name: child.path) else { continue }

            let childLogicalPath = (currentLogicalPath as NSString).appendingPathComponent(child.path)

            if isLastSegment {
                // Final segment — emit the match.
                results.append(FileWildcardEntry(path: childLogicalPath, kind: child.kind))
            } else if child.kind == .folder {
                // More segments remain — descend into matching folder.
                let childPhysicalPath = (currentDirectory as NSString).appendingPathComponent(child.path)
                matchSegments(
                    segments: segments,
                    segmentIndex: segmentIndex + 1,
                    currentDirectory: childPhysicalPath,
                    currentLogicalPath: childLogicalPath,
                    results: &results
                )
            }
            // If more segments remain but child is a file, it cannot match — skip.
        }
    }

    // MARK: - Segment-level glob matching

    /// Match a single path-segment name against a glob pattern that may
    /// contain `*` (any run of characters) and `?` (any single character).
    private func segmentMatches(pattern: String, name: String) -> Bool {
        globMatch(
            pattern: Array(pattern.unicodeScalars),
            pi: 0,
            text: Array(name.unicodeScalars),
            ti: 0
        )
    }

    /// Classic two-pointer glob matcher supporting `*` and `?`.
    private func globMatch(
        pattern: [Unicode.Scalar],
        pi: Int,
        text: [Unicode.Scalar],
        ti: Int
    ) -> Bool {
        var pi = pi
        var ti = ti
        var starPI = -1     // position in pattern after last `*`
        var starTI = -1     // position in text when last `*` was seen

        while ti < text.count {
            if pi < pattern.count && (pattern[pi] == "?" || pattern[pi] == text[ti]) {
                pi += 1
                ti += 1
            } else if pi < pattern.count && pattern[pi] == "*" {
                starPI = pi + 1
                starTI = ti
                pi += 1
            } else if starPI != -1 {
                // Backtrack: let the last `*` consume one more character.
                starTI += 1
                ti = starTI
                pi = starPI
            } else {
                return false
            }
        }

        // Consume any trailing `*` characters in the pattern.
        while pi < pattern.count && pattern[pi] == "*" {
            pi += 1
        }

        return pi == pattern.count
    }
}

final class ExternalFileSystemLister: FileWildcardMatcherInput {
    let rootDirectoryPath: String

    init(rootDirectoryPath: String) {
        self.rootDirectoryPath = rootDirectoryPath
    }

    func allFiles(inDirectoryPath path: String) -> [FileWildcardEntry] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(atPath: path) else {
            return []
        }
        return children.compactMap { name in
            // Skip hidden files
            guard !name.hasPrefix(".") else { return nil }
            let fullPath = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else { return nil }
            return FileWildcardEntry(
                path: name,
                kind: isDir.boolValue ? .folder : .file
            )
        }.sorted { $0.path < $1.path }
    }
}

final class InternalFileSystemLister: FileWildcardMatcherInput {
    let rootDirectoryPath = "/"
    let folder: Folder

    init(folder: Folder) {
        self.folder = folder
    }

    func allFiles(inDirectoryPath: String) -> [FileWildcardEntry] {
        let start = folder.child(path: inDirectoryPath)! // TODO
        return try! start.allChildren().map { node in
            FileWildcardEntry(path: node.nodeContext.name!, kind: node is StaticFileNode ? .file : .folder)
        }
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
    case copy(folder: FileSystemForCommand, pathOrWildcard: String, destinationPath: String)   // strato cp [-i] /Example/src/myfile.c .
    case list(folder: FileSystemForCommand, pathOrWildcard: String) // strato ls [-i] /Example/**/*.c
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
            let (folder, remaining) = parseFileSystemFlag(tokens: tokens)
            guard remaining.count >= 2 else {
                throw CommandParserError.missingArgument(command: "cp", expected: "pathOrWildcard destinationPath")
            }
            return .copy(folder: folder, pathOrWildcard: remaining[0], destinationPath: remaining[1])

        case "ls", "list":
            let (folder, remaining) = parseFileSystemFlag(tokens: tokens)
            guard let path = remaining.first else {
                throw CommandParserError.missingArgument(command: "ls", expected: "pathOrWildcard")
            }
            return .list(folder: folder, pathOrWildcard: path)

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

final class ExternalPathSanitizer {

    static func expandPartialPath(_ path: String) -> String {
        var expanded = path

        // Expand ~ to the user's home directory
        if expanded.hasPrefix("~") {
            expanded = (expanded as NSString).expandingTildeInPath
        }

        // If the path is not absolute, resolve it relative to the current working directory
        if !expanded.hasPrefix("/") {
            let cwd = FileManager.default.currentDirectoryPath
            expanded = (cwd as NSString).appendingPathComponent(expanded)
        }

        // Resolve . and .. components and produce a canonical absolute path
        expanded = (expanded as NSString).standardizingPath

        // Resolve any symlinks to get a fully canonical path
        let resolved = (expanded as NSString).resolvingSymlinksInPath

        return resolved
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
            try handleRemove(pathOrWildcard: pathOrWildcard)

        case .copy(let folder, let pathOrWildcard, let destinationPath):
            try handleCopy(folder: folder, pathOrWildcard: pathOrWildcard, destinationPath: destinationPath)

        case .list(let folder, let pathOrWildcard):
            try handleList(folder: folder, pathOrWildcard: pathOrWildcard)

        }
    }

    private func handleBase(externalPath: String) {
        guard !externalPath.isEmpty else {
            outputError("Base path cannot be empty")
            return
        }

        let expandedPath = ExternalPathSanitizer.expandPartialPath(externalPath)

        if !FileManager.default.fileExists(atPath: expandedPath) {
            outputError("Path refers to nonexistent directory: \(externalPath)")
            return
        }

        baseDirectory = expandedPath
        outputMessage("Base directory set to \(expandedPath)")
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

    var inputFileSystem: Folder {
        get throws {
            try nodeContext.processingCycle.rootNode.inputFileSystem
        }
    }

    var outputFileSystem: Folder { // TODO: this is inside the buildgraph node because it is a product of the graph
        get throws {
            try child(named: "outputFileSystem")
        }
    }

    func pushOne(_ entry: FileWildcardEntry, baseDirectory: String) {
        let relativePath = entry.path.relativeTo(baseDirectory)
        outputMessage("Push: \(relativePath)")
        switch entry.kind {

        case .file:
//            inputFileSystem.ensureEntirePathExists(relativePath.deletingLastPathComponent)

            // locate the file in the external file system
            // read the file
            let fileContent = try! [UInt8](Data(contentsOf: URL(fileURLWithPath: entry.path)))

            // if it does not already exist, synchronously create a new Node representing this file in the internal file system

            // if it does already exist, write to its input port with the file content, which should cause it to emit mutation events if the content has changed
            // creating a new Node will cause its parent folder to emit mutation events, and its parent, all the way to the root folder
            // mutation events will be queued on other Nodes that are subscribed
            let filename = relativePath // TODO: the last bit
            try! inputFileSystem.addOrReplaceChild(content: fileContent.intern(), name: filename)

            break

        case .folder:
//            inputFileSystem.ensureEntirePathExists(relativePath)
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
            pushOne(entry, baseDirectory: baseDirectory)
        }
    }

    private func handleRemove(pathOrWildcard: String) throws {
        let matcher = FileWildcardMatcher(input: InternalFileSystemLister(folder: try inputFileSystem))

        matcher.findAllMatching(pathOrWildcard: pathOrWildcard).forEach { entry in
            removeOne(entry)
        }
    }

    private func removeOne(_ entry: FileWildcardEntry) {
//        inputFileSystem.removeChild(path: entry.path)

        // locate the file or folder in the internal file system
        // if it does not exist, report error to user
        // if it is a folder, recursively remove all files and folders inside
        // remove the Node representing this file or folder from the internal file system
        // deleting a Node will cause its parent folder to emit mutation events, and its parent, all the way to the root folder
        // deleting a Node that has Wires will cause wire-removed events for wire targets
        // mutation events will be queued on other Nodes that are subscribed
    }

    private func handleCopy(folder: FileSystemForCommand, pathOrWildcard: String, destinationPath: String) throws {
        func handle(folder: Folder) {
            let matcher = FileWildcardMatcher(input: InternalFileSystemLister(folder: folder))

            matcher.findAllMatching(pathOrWildcard: pathOrWildcard).forEach { entry in
                copyOneFile(folder: folder, entry: entry, destinationPath: destinationPath)
            }
        }

        switch folder {
        case .input:
            handle(folder: try inputFileSystem)
        case .output:
            handle(folder: try outputFileSystem)
        }
    }

    private func copyOneFile(folder: Folder, entry: FileWildcardEntry, destinationPath: String) {
/*        let node = folder.childNode(path: entry.path)

        if let staticFileNode = node as? StaticFileNode {
            let fileContent: [UInt8] = staticFileNode.outputValue.content

            fileContent.write(to: URL(fileURLWithPath: destinationPath))
        } else {
            if let folderNode = node as? FileSystem {
                // TODO: create a folder in external FS to match the one in the internal file system
            }
        }*/
    }

    private func handleList(folder: FileSystemForCommand, pathOrWildcard: String) throws {
        let matcher = FileWildcardMatcher(input: InternalFileSystemLister(folder: try inputFileSystem))

        matcher.findAllMatching(pathOrWildcard: pathOrWildcard).forEach { entry in
            outputMessage(entry.path)
        }
    }

    func processInputs(_ inputs: [NodeKindDescriptor.InputPort: [NodeInputMessage]?]) throws -> [NodeKindDescriptor.OutputPort: NodeProcessPortOutput?] {
        [:]
    }
}
