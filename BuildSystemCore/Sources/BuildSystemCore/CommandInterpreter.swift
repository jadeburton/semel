//
//  CommandInterpreter.swift
//  build_system
//

import Foundation

private extension String {
    func relativeTo(_ baseDirectory: String) -> String {
        let base = baseDirectory.hasSuffix("/") ? baseDirectory : baseDirectory + "/"
        return hasPrefix(base) ? String(dropFirst(base.count)) : self
    }
}

enum CommandInterpreterError: Error {
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

    func outputMessage(_ message: String) { print(message) }
    func outputError(_ errorMessage: String) { print(errorMessage) }

    func handleCommand(_ command: String) throws {
        do {
            try handleUserCommand(commandParser.parse(command: command))
        } catch CommandInterpreterError.quit {
            throw CommandInterpreterError.quit
        } catch let error as NodeError {
            outputError("\(error)") // HACK
        } catch {
            outputError(error.localizedDescription)
        }
    }

    var buildEngine: BuildEngine { BuildEngine.shared }

    func handleUserCommand(_ userCommand: UserCommand) throws {
        switch userCommand {
        case .base(let externalPath):               handleBase(externalPath: externalPath)
        case .debug:                                try handleDebug()
        case .nudge:                                try handleNudge()
        case .quit:                                 try handleQuit()
        case .begin:                                handleBegin()
        case .commit:                               handleCommit()
        case .discard:                              handleDiscard()
        case .push(let p):                          try handlePush(externalPathOrWildcard: p)
        case .remove(let p):                        try handleRemove(pathOrWildcard: p)
        case .copy(let f, let p, let d):            try handleCopy(folder: f, pathOrWildcard: p, destinationPath: d)
        case .list(let f, let p):                   try handleList(folder: f, pathOrWildcard: p)
        case .errors:                               try handleErrors()
        }
    }

    // MARK: - Simple commands

    private func handleDebug()  throws { try buildEngine.printAll() }
    private func handleNudge()  throws { try buildEngine.nudge() }
    private func handleQuit()   throws { throw CommandInterpreterError.quit }
    private func handleBegin()  {}
    private func handleCommit() {}
    private func handleDiscard(){}

    // MARK: - Base

    private func handleBase(externalPath: String) {
        guard !externalPath.isEmpty else {
            outputError("Base path cannot be empty"); return
        }
        let expandedPath = ExternalPathSanitizer.expandPartialPath(externalPath)
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            outputError("Path refers to nonexistent directory: \(externalPath)"); return
        }
        baseDirectory = expandedPath
        outputMessage("Base directory set to \(expandedPath)")
    }

    // MARK: - File system accessors

    var inputFileSystem: Node  { get throws { try buildEngine.inputFileSystem } }
    var outputFileSystem: Node { get throws { try buildEngine.outputFileSystem } }

    // MARK: - Push

    func pushOne(_ entry: FileWildcardEntry, baseDirectory: String) throws {
        let relativePath = entry.path
        outputMessage("Push: \(relativePath)")

        switch entry.kind {
        case .file:
            let absolutePath = (baseDirectory as NSString)
                .appendingPathComponent(relativePath.string)
            let fileContent  = try! [UInt8](Data(contentsOf: URL(fileURLWithPath: absolutePath)))

            _ = try inputFileSystem.ensureEntirePathExistsAsFolders(
                    relativePath.deletingLastComponent ?? .empty, pinned: true)

            let pathIncludingInputFileSystem = Path("inputFileSystem") / relativePath
            let graphShapeNode = try GraphShapeNode.parse("StaticFile(path: '\(pathIncludingInputFileSystem.string)')")
            let (fromNodeID, _) = try graphShapeNode.findOrCreateMatchingNode()
            let fromNode = try database.node.select(nodeID: fromNodeID)
            _ = try (fromNode.nodeFunctionCast() as StaticFile).replaceContent(fileContent.intern())

        case .folder:
            _ = try inputFileSystem.ensureEntirePathExistsAsFolders(relativePath, pinned: true)
        }
    }

    private func handlePush(externalPathOrWildcard: String) throws {
        guard let baseDirectory else {
            outputError("Set a base directory before pushing files"); return
        }
        let matcher = FileWildcardMatcher(input: ExternalFileSystemLister(rootDirectoryPath: baseDirectory))
        try matcher.findAllMatching(pathOrWildcard: externalPathOrWildcard).forEach { entry in
            try pushOne(entry, baseDirectory: baseDirectory)
        }
    }

    // MARK: - Remove

    private func handleRemove(pathOrWildcard: String) throws {
        let matcher = FileWildcardMatcher(input: InternalFileSystemLister(folder: try inputFileSystem))
        try matcher.findAllMatching(pathOrWildcard: pathOrWildcard).forEach { entry in
            try removeOne(entry)
        }
    }

    private func removeOne(_ entry: FileWildcardEntry) throws {
        guard let child = try inputFileSystem.childNode(path: entry.path) else {
            outputError("Child not found: \(entry.path)");
            return
        }

        guard let userDeletableChild = try child.nodeFunction() as? UserDeletable else {
            outputError("Child not deletable: \(entry.path)");
            return
        }

        try userDeletableChild.deleteInInputFileSystem()
    }

    // MARK: - Copy

    private func handleCopy(folder: FileSystemForCommand, pathOrWildcard: String,
                             destinationPath: String?) throws {
        func handle(folder: Node) throws {
            let matcher = FileWildcardMatcher(input: InternalFileSystemLister(folder: folder))
            try matcher.findAllMatching(pathOrWildcard: pathOrWildcard).forEach { entry in
                try? copyOneFile(folder: folder, entry: entry,
                                 destinationPath: destinationPath ?? ".")
            }
        }
        switch folder {
        case .input:  try handle(folder: inputFileSystem)
        case .output: try handle(folder: outputFileSystem)
        }
    }

    private func copyOneFile(folder: Node, entry: FileWildcardEntry,
                              destinationPath: String) throws {
        guard case .file = entry.kind else { return }

        guard let fileNode = try folder.childNode(path: entry.path) else {
            outputError("File \(entry.path) not found in internal file system"); return
        }
        guard let file = try fileNode.nodeFunction() as? FileType else {
            outputError("Object \(entry.path) is not a FileType"); return
        }

        switch try file.read() {
        case .value(let dataObjectHash):
            let fileContent = Data(try dataObjectHash.resolve())
            let finalPath   = destinationPath + "/" + (entry.path.lastComponent ?? entry.path.string)
            try fileContent.write(to: URL(fileURLWithPath: finalPath))
            outputMessage("File written: \(finalPath)")
        case .noValue(let reason):
            outputError("File \(entry.path) has no content: \(reason)")
        case nil:
            outputError("File \(entry.path) has no nil value")
        }
    }

    // MARK: - Errors

    private func handleErrors() throws {
        let errorPorts = try database.outputPort.selectAllErrors()

        if errorPorts.isEmpty { outputMessage("No errors."); return }

        let byNode     = Dictionary(grouping: errorPorts, by: \.nodeID)
        let errorCount = errorPorts.count
        let nodeCount  = byNode.count

        let sortedNodeIDs = byNode.keys.sorted { a, b in
            let nameA = (try? database.node.select(nodeID: a))?.name ?? ""
            let nameB = (try? database.node.select(nodeID: b))?.name ?? ""
            return nameA < nameB
        }

        outputMessage("\(errorCount) error\(errorCount == 1 ? "" : "s") across " +
                      "\(nodeCount) node\(nodeCount == 1 ? "" : "s"):\n")

        for nodeID in sortedNodeIDs {
            let node     = try? database.node.select(nodeID: nodeID)
            let nodeName = node?.name ?? "Node \(nodeID)"

            let kindLabel: String
            if let node, let nf = try? node.nodeFunction() {
                let typeName = String(describing: type(of: nf))
                kindLabel = typeName == nodeName ? nodeName : "\(nodeName)  [\(typeName)]"
            } else {
                kindLabel = nodeName
            }

            outputMessage("❌ \(kindLabel)")

            for port in byNode[nodeID]! {
                let portName     = port.nameSymbolID.resolveSymbol()
                let errorMessage = (try? port.dataObjectHash?.resolveAsString()) ?? ""

                if errorMessage.isEmpty {
                    outputMessage("   · \(portName): (no details)")
                } else {
                    let lines = errorMessage
                        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                        .components(separatedBy: "\n")
                        .map    { $0.trimmingCharacters(in: CharacterSet.whitespaces) }
                        .filter { !$0.isEmpty }

                    if lines.count == 1 {
                        outputMessage("   · \(portName): \(lines[0])")
                    } else {
                        outputMessage("   · \(portName):")
                        lines.forEach { outputMessage("     \($0)") }
                    }
                }
            }
            outputMessage("")
        }
    }

    // MARK: - List

    private func handleList(folder: FileSystemForCommand, pathOrWildcard: String) throws {
        let fileSystem: Node
        switch folder {
        case .input:  fileSystem = try inputFileSystem
        case .output: fileSystem = try outputFileSystem
        }

        let matcher  = FileWildcardMatcher(input: InternalFileSystemLister(folder: fileSystem))
        let pattern  = Path(pathOrWildcard)

        // If the pattern has no wildcards and resolves to a single folder, list its
        // immediate children (like `ls folderName` in a shell).
        var results = try matcher.findAllMatching(pathOrWildcard: pattern)

        if !pattern.containsWildcard, results.count == 1, results[0].kind == .folder {
            results = try matcher.findAllMatching(pathOrWildcard: results[0].path / "*")
        }

        if results.isEmpty { outputMessage("(empty)"); return }

        for entry in results {
            let suffix = entry.kind == .folder ? "/" : ""
            if entry.isMissing {
                outputMessage("\(entry.path)\(suffix) (missing)")
            } else if entry.isUnreferenced {
                outputMessage("\(entry.path)\(suffix) (unreferenced)")
            } else {
                outputMessage("\(entry.path)\(suffix)")
            }
        }
    }
}
