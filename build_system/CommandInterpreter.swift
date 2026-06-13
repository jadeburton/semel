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
    let isMissing: Bool // the file is missing from the internal file system (e.g. it was deleted by the user but is still referenced by the build graph)
    let isUnreferenced: Bool
}

protocol FileWildcardMatcherInput {
    var rootDirectoryPath: String { get }

    func allFiles(inDirectoryPath: String) throws -> [FileWildcardEntry]
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
    func findAllMatching(pathOrWildcard: String) throws -> [FileWildcardEntry] {
        let normalised = pathOrWildcard.hasPrefix("/")
            ? pathOrWildcard
            : "/" + pathOrWildcard

        let segments = normalised
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        var results: [FileWildcardEntry] = []
        try matchSegments(
            segments: segments,
            segmentIndex: 0,
            currentDirectory: input.rootDirectoryPath,
            currentLogicalPath: "",
            results: &results
        )
        return results
    }

    // MARK: - Private recursive matcher

    /// Join a logical path prefix with a child name, producing a clean relative path (no leading /).
    private func joinLogicalPath(_ base: String, _ child: String) -> String {
        base.isEmpty ? child : base + "/" + child
    }

    /// Recursively walk the directory tree, consuming pattern segments as they
    /// match entries returned by `input.allFiles(inDirectoryPath:)`.
    private func matchSegments(
        segments: [String],
        segmentIndex: Int,
        currentDirectory: String,
        currentLogicalPath: String,
        results: inout [FileWildcardEntry]
    ) throws {
        // All segments consumed — nothing more to match.
        guard segmentIndex < segments.count else { return }

        let segment = segments[segmentIndex]
        let isLastSegment = segmentIndex == segments.count - 1

        // ── ** (double-star / globstar) ──────────────────────────────
        if segment == "**" {
            // ** can match zero directories (skip it) …
            try matchSegments(
                segments: segments,
                segmentIndex: segmentIndex + 1,
                currentDirectory: currentDirectory,
                currentLogicalPath: currentLogicalPath,
                results: &results
            )

            // … or match one-or-more directories (recurse into each child dir).
            let children = try input.allFiles(inDirectoryPath: currentDirectory)
            for child in children {
                let childLogicalPath = joinLogicalPath(currentLogicalPath, child.path)

                if child.kind == .folder {
                    let childPhysicalPath = (currentDirectory as NSString).appendingPathComponent(child.path)

                    // Keep consuming ** in this subfolder.
                    try matchSegments(
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
        let children = try input.allFiles(inDirectoryPath: currentDirectory)

        for child in children {
            guard segmentMatches(pattern: segment, name: child.path) else { continue }

            let childLogicalPath = joinLogicalPath(currentLogicalPath, child.path)

            if isLastSegment {
                // Final segment — emit the match.
                results.append(FileWildcardEntry(path: childLogicalPath,
                                                 kind: child.kind,
                                                 isMissing: child.isMissing,
                                                 isUnreferenced: child.isUnreferenced))

            } else if child.kind == .folder {
                // More segments remain — descend into matching folder.
                let childPhysicalPath = (currentDirectory as NSString).appendingPathComponent(child.path)
                try matchSegments(
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
                kind: isDir.boolValue ? .folder : .file,
                isMissing: false,
                isUnreferenced: false
            )
        }.sorted { $0.path < $1.path }
    }
}

final class InternalFileSystemLister: FileWildcardMatcherInput {
    let rootDirectoryPath = "/"
    let folder: Node

    init(folder: Node) {
        self.folder = folder
    }

    func allFiles(inDirectoryPath: String) throws -> [FileWildcardEntry] {
        let start = try folder.childNode(path: inDirectoryPath)! // TODO

        return try! start.allChildren.map { node in

            switch node.kind {

            case Folder.kind:
                guard let folder = try node.nodeFunction() as? Folder else {
                    throw NodeError.other(message: "Unexpected object kind")
                }
                return FileWildcardEntry(path: node.name!,
                                         kind: .folder,
                                         isMissing: false,
                                         isUnreferenced: try folder.hasNoOutputWires() && node.allChildren.isEmpty)

            default:
                let nodeFunction = try node.nodeFunction()
                guard let file = nodeFunction as? FileType else {
                    throw NodeError.other(message: "Unexpected object kind")
                }
                return FileWildcardEntry(path: node.name!,
                                         kind: .file,
                                         isMissing: try file.read()!.isNoValue,
                                         isUnreferenced: try nodeFunction.hasNoOutputWires())
            }
        }
    }
}

enum FileSystemForCommand {
    case input
    case output
}

enum UserCommand {
    case base(externalPath: String) // strato base .
    case debug
    case nudge // schedule all nodes currently in an error state
    case quit
    case begin           // strato begin
    case commit          // strato commit
    case discard         // strato discard
    case push(externalPathOrWildcard: String) // strato push Example/src/myfile.c
    case remove(pathOrWildcard: String) // strato rm /**/*.*
    case copy(folder: FileSystemForCommand, pathOrWildcard: String, destinationPath: String?)   // strato cp [-i] /Example/src/myfile.c .
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

        case "d", "debug":
            return .debug

        case "n", "nudge":
            return .nudge

        case "q", "quit", "exit":
            return .quit

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
            guard remaining.count >= 1 else {
                throw CommandParserError.missingArgument(command: "cp", expected: "pathOrWildcard [destinationPath]")
            }
            return .copy(folder: folder, pathOrWildcard: remaining[0], destinationPath: remaining.count >= 2 ? remaining[1] : nil)

        case "ls", "list":
            let (folder, remaining) = parseFileSystemFlag(tokens: tokens)
            let path = remaining.first ?? "*"
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

enum  CommandInterpreterError: Error {
    case quit
}

final class CommandInterpreter {

    let commandParser = CommandParser()
    var baseDirectory: String?
    let database: DatabaseLayer

    required init(database: DatabaseLayer) {
        self.database = database
        handleBase(externalPath: "/Users/jadeburton/Desktop/C1/C1")
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
            //  try save()
        } catch CommandInterpreterError.quit {
            throw CommandInterpreterError.quit
        } catch {
            outputError(error.localizedDescription)
        }
    }

    var buildEngine: BuildEngine {
        BuildEngine.shared
    }

    func handleDebug() throws {
        try buildEngine.printAll()
    }

    func handleNudge() throws {
        try buildEngine.nudge()
    }

    func handleQuit() throws {
        throw CommandInterpreterError.quit
    }

    func handleUserCommand(_ userCommand: UserCommand) throws {
        switch userCommand {

        case .base(let externalPath):
            handleBase(externalPath: externalPath)

        case .debug:
            try handleDebug()

        case .nudge:
            try handleNudge()

        case .quit:
            try handleQuit()

        case .begin:
            handleBegin()

        case .commit:
            handleCommit()

        case .discard:
            handleDiscard()

        case .push(let externalPathOrWildcard):
            try handlePush(externalPathOrWildcard: externalPathOrWildcard)

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

    var inputFileSystem: Node {
        get throws {
            try buildEngine.inputFileSystem
        }
    }

    var outputFileSystem: Node {
        get throws {
            try buildEngine.outputFileSystem
        }
    }

    func pushOne(_ entry: FileWildcardEntry, baseDirectory: String) throws {
        let relativePath = entry.path
        outputMessage("Push: \(relativePath)")
        switch entry.kind {

        case .file:
            let absolutePath = (baseDirectory as NSString).appendingPathComponent(relativePath)
            let fileContent = try! [UInt8](Data(contentsOf: URL(fileURLWithPath: absolutePath)))

            let graphShapeNode = try GraphShapeNode.parse("StaticFile(path: '\(relativePath)')")
            let (fromNodeID, _) = try graphShapeNode.findOrCreateMatchingNode()
            let fromNode = try database.node.select(nodeID: fromNodeID)
            _ = try (fromNode.nodeFunctionCast() as StaticFile).replaceContent(fileContent.intern())

        case .folder:
            // TODO: each folder should notify its parent of creation
            _ = try inputFileSystem.ensureEntirePathExistsAsFolders(relativePath)
        }
    }

    private func handlePush(externalPathOrWildcard: String) throws {
        guard let baseDirectory else {
            outputError("Set a base directory before pushing files")
            return
        }

        let matcher = FileWildcardMatcher(input: ExternalFileSystemLister(rootDirectoryPath: baseDirectory))

        try matcher.findAllMatching(pathOrWildcard: externalPathOrWildcard).forEach { entry in
            try pushOne(entry, baseDirectory: baseDirectory)
        }
    }

    private func handleRemove(pathOrWildcard: String) throws {
        let matcher = FileWildcardMatcher(input: InternalFileSystemLister(folder: try inputFileSystem))

        try matcher.findAllMatching(pathOrWildcard: pathOrWildcard).forEach { entry in
            try removeOne(entry)
        }
    }

    private func removeOne(_ entry: FileWildcardEntry) throws {
        guard let child = try inputFileSystem.childNode(path: entry.path) else {
            outputError("Child not found")
            return
        }

        try removeOne(child: child)
    }

    private func removeOne(child: Node) throws {
        if let staticFile = try child.nodeFunction() as? StaticFile {
            try removeStaticFile(nodeFunction: staticFile)
        } else {
            if let folder = try child.nodeFunction() as? Folder {
                try removeFolder(node: child, nodeFunction: folder)
            } else {
                // TODO
                assert(false)
            }
        }
    }

    private func removeStaticFile(nodeFunction: StaticFile) throws {
        outputMessage("Remove file: \(nodeFunction.thisNode.name!)")

        // This automatically notifies the parent Folder, which is important, as it should no longer include the ghost in its manifest.
        // (The ProjectFinder needs to know when a Project becomes a ghost - so it can remove the corresponding ProjectBuilder and release
        // the Project file.)
        _ = try nodeFunction.replaceContent(nil) // turns it into a ghost

        if try nodeFunction.hasNoOutputWires() && nodeFunction.canBeDeleted() {
            // Ghost, no output wires - really delete it.
            _ = try database.node.delete(nodeID: nodeFunction.thisNode.id!)

            // notify parent
            if let parentNodeID = nodeFunction.thisNode.parentNodeID {
                let parentFolderNode = try database.node.select(nodeID: parentNodeID)
                try (parentFolderNode.nodeFunctionCast() as Folder).notifyChildContentChanged(nodeID: nodeFunction.thisNode.id!,
                                                                                              name: nodeFunction.thisNode.name!,
                                                                                              thisNode: parentFolderNode)
            }
        }

        // - if the Node is used by the build graph, it must not be user-deleted, as this will invalidate the graph even if the file is re-added.
        // - instead, we "gut" the file, turning it into a ghost. when the user lists files, it will appear as "missing", according to the current build graph.
        // - then, re-adding the file will replace the ghost with a new node, which will be picked up by the build graph and cause the necessary rebuilds.
    }

    private func removeFolder(node: Node, nodeFunction: Folder) throws {

        // Delete all children first, which will make child StaticFiles ghosts
        for child in try node.allChildren {
            try removeOne(child: child)
        }

        outputMessage("Remove folder: \(node.name!)")

        if try nodeFunction.hasNoOutputWires() && nodeFunction.canBeDeleted() {
            _ = try database.node.delete(nodeID: node.id!)

            if let parentNodeID = node.parentNodeID {
                let parentFolderNode = try database.node.select(nodeID: parentNodeID)
                try (parentFolderNode.nodeFunctionCast() as Folder).notifyChildContentChanged(nodeID: node.id!,
                                                                                              name: node.name!,
                                                                                              thisNode: parentFolderNode)
            }
        } else {
            // TODO: If there are no children but there are outputs, mark the folder as a ghost. Parent folder should not include in manifest.
            outputError("Cannot delete Folder; in use")
        }
    }

    private func handleCopy(folder: FileSystemForCommand, pathOrWildcard: String, destinationPath: String?) throws {
        func handle(folder: Node) throws {
            let matcher = FileWildcardMatcher(input: InternalFileSystemLister(folder: folder))

            try matcher.findAllMatching(pathOrWildcard: pathOrWildcard).forEach { entry in
                try? copyOneFile(folder: folder, entry: entry, destinationPath: destinationPath ?? ".")
            }
        }

        switch folder {
        case .input:
            try handle(folder: inputFileSystem)
        case .output:
            try handle(folder: outputFileSystem)
        }
    }

    private func copyOneFile(folder: Node, entry: FileWildcardEntry, destinationPath: String) throws {
        switch entry.kind {
        case .file:
            guard let fileNode = try folder.childNode(path: entry.path) else {
                outputError("File \(entry.path) not found in internal file system")
                return
            }

            guard let file = try fileNode.nodeFunction() as? FileType else {
                outputError("Object \(entry.path) is not a FileType")
                return
            }

            switch try file.read() {

            case .value(let dataObjectHash):
                let fileContent = Data(try dataObjectHash.resolve())
                let finalPath = destinationPath.appending("/").appending((entry.path as NSString).lastPathComponent)
                try fileContent.write(to: URL(fileURLWithPath: finalPath))
                outputMessage("File written: \(finalPath)")

            case .noValue(let reason):
                outputError("File \(entry.path) has no content: \(reason)")

            case nil:
                outputError("File \(entry.path) has no nil value")

            }

        case .folder:
            break
            // TODO
        }
    }

    private func handleList(folder: FileSystemForCommand, pathOrWildcard: String) throws {
        let fileSystem: Node

        switch folder {
        case .input:
            fileSystem = try inputFileSystem
        case .output:
            fileSystem = try outputFileSystem
        }

        let matcher = FileWildcardMatcher(input: InternalFileSystemLister(folder: fileSystem))

        try matcher.findAllMatching(pathOrWildcard: pathOrWildcard).forEach { entry in
            if entry.isMissing {
                outputMessage("\(entry.path) (missing)")
            } else {
                if entry.isUnreferenced {
                    outputMessage("\(entry.path) (unreferenced)")
                } else {
                    outputMessage(entry.path)
                }
            }
        }
    }
}
