// FilePlugin.swift
// build_system
//
// Handles: push, rm / remove, cp / copy

import BuildSystemCore
import Foundation

final class FilePlugin: CommandPlugin {

    let verbs: Set<String> = ["push", "rm", "remove", "cp", "copy"]

    func handle(verb: String, tokens: [String], context: any CommandContext) throws {
        switch verb {
        case "push":
            guard let path = tokens.first else {
                throw CommandParserError.missingArgument(command: "push", expected: "pathOrWildcard")
            }
            try handlePush(externalPathOrWildcard: path, context: context)

        case "rm", "remove":
            guard let path = tokens.first else {
                throw CommandParserError.missingArgument(command: "rm", expected: "pathOrWildcard")
            }
            try handleRemove(pathOrWildcard: path, context: context)

        case "cp", "copy":
            let (folder, remaining) = parseFileSystemFlag(tokens: tokens)
            guard remaining.count >= 1 else {
                throw CommandParserError.missingArgument(command: "cp",
                                                         expected: "pathOrWildcard [destinationPath]")
            }
            try handleCopy(folder: folder, pathOrWildcard: remaining[0],
                           destinationPath: remaining.count >= 2 ? remaining[1] : nil,
                           context: context)

        default:
            break
        }
    }

    // MARK: - push

    private func handlePush(externalPathOrWildcard: String, context: any CommandContext) throws {
        BuildEngine.shared.beginBatch()
        defer { BuildEngine.shared.endBatch() }

        // Resolve the user-supplied wildcard relative to the internal current directory
        // so that "push *.c" from "src/a" reads baseDirectory/src/a/*.c and stores
        // the files at input:/src/a/*.c.
        let current = context.currentDirectoryPath
        let effectiveWildcard = current.isEmpty
            ? externalPathOrWildcard
            : current.string + "/" + externalPathOrWildcard

        let matcher = FileWildcardMatcher(input: ExternalFileSystemLister(rootDirectoryPath: context.baseDirectory))
        try matcher.findAllMatching(pathOrWildcard: effectiveWildcard).forEach { entry in
            try pushOne(entry, baseDirectory: context.baseDirectory, context: context)
        }
    }

    private func pushOne(_ entry: FileWildcardEntry, baseDirectory: String,
                          context: any CommandContext) throws {
        let relativePath = entry.path
        context.outputMessage("Push: \(relativePath)")

        switch entry.kind {
        case .file:
            let absolutePath = (baseDirectory as NSString).appendingPathComponent(relativePath.string)
            let fileContent  = try! [UInt8](Data(contentsOf: URL(fileURLWithPath: absolutePath)))

            _ = try context.inputFileSystem.ensureEntirePathExistsAsFolders(
                    relativePath.deletingLastComponent ?? .empty, pinned: true)

            let fullPath      = Path(Folder.inputFileSystemName) / relativePath
            let graphShapeNode = try GraphShapeNode.parse("StaticFile(path: '\(fullPath.string)')")
            let (fromNode, _) = try graphShapeNode.findOrCreateMatchingNode()
            _ = try (fromNode.nodeAsAny() as! StaticFile).replaceContent(fileContent.intern())

        case .folder:
            _ = try context.inputFileSystem.ensureEntirePathExistsAsFolders(relativePath, pinned: true)
            // Recursively push every file inside the directory.
            // Only .file entries are forwarded to pushOne; folder nodes are created
            // implicitly by ensureEntirePathExistsAsFolders when each file is pushed.
            let subMatcher = FileWildcardMatcher(input: ExternalFileSystemLister(rootDirectoryPath: baseDirectory))
            try subMatcher.findAllMatching(pathOrWildcard: relativePath.string + "/**/*").forEach { child in
                if case .file = child.kind {
                    try pushOne(child, baseDirectory: baseDirectory, context: context)
                }
            }
        }
    }

    // MARK: - rm

    private func handleRemove(pathOrWildcard: String, context: any CommandContext) throws {
        let base = context.currentDirectoryPath
        let fullPattern: Path = base.isEmpty ? Path(pathOrWildcard) : base / pathOrWildcard

        let matcher = FileWildcardMatcher(input: InternalFileSystemLister(folder: try context.inputFileSystem))
        let entries = try matcher.findAllMatching(pathOrWildcard: fullPattern)

        guard !entries.isEmpty else {
            context.outputError("rm: \(pathOrWildcard): no such file or directory")
            return
        }

        for entry in entries {
            try removeOne(entry, context: context)
        }
    }

    private func removeOne(_ entry: FileWildcardEntry, context: any CommandContext) throws {
        guard let child = try context.inputFileSystem.childNode(path: entry.path) else {
            context.outputError("Child not found: \(entry.path)"); return
        }
        guard let userDeletableChild = try child.nodeAsAny() as? UserDeletable else {
            context.outputError("Child not deletable: \(entry.path)"); return
        }
        try userDeletableChild.deleteInInputFileSystem()
    }

    // MARK: - cp

    private func handleCopy(folder: FileSystemForCommand, pathOrWildcard: String,
                             destinationPath: String?, context: any CommandContext) throws {
        let fileSystem = try context.fileSystem(for: folder)
        let matcher    = FileWildcardMatcher(input: InternalFileSystemLister(folder: fileSystem))

        // Resolve internal source relative to the current directory (same as rm).
        let base = context.currentDirectoryPath
        let fullPattern = base.isEmpty ? Path(pathOrWildcard) : base / pathOrWildcard

        // Resolve external destination relative to baseDirectory/currentDirectoryPath.
        let externalDest = resolveExternalDestination(destinationPath ?? ".", context: context)

        try matcher.findAllMatching(pathOrWildcard: fullPattern).forEach { entry in
            try? copyOneFile(folder: fileSystem, entry: entry,
                             destinationPath: externalDest, context: context)
        }
    }

    /// Resolves an external destination path.
    /// Absolute OS paths (starting with "/" or "~") are left as-is; relative paths
    /// are resolved against baseDirectory/currentDirectoryPath.
    private func resolveExternalDestination(_ path: String, context: any CommandContext) -> String {
        if path.hasPrefix("/") || path.hasPrefix("~") {
            return ExternalPathSanitizer.expandPartialPath(path)
        }
        let current = context.currentDirectoryPath
        let externalBase = current.isEmpty
            ? context.baseDirectory
            : (context.baseDirectory as NSString).appendingPathComponent(current.string)
        return (externalBase as NSString).appendingPathComponent(path)
    }

    private func copyOneFile(folder: Node, entry: FileWildcardEntry,
                              destinationPath: String, context: any CommandContext) throws {
        guard case .file = entry.kind else { return }

        guard let fileNode = try folder.childNode(path: entry.path) else {
            context.outputError("File \(entry.path) not found in internal file system"); return
        }
        guard let file = try fileNode.nodeAsAny() as? FileType else {
            context.outputError("Object \(entry.path) is not a FileType"); return
        }

        switch try file.read() {
        case .value(let dataObjectHash):
            let fileContent = Data(try dataObjectHash.resolve())
            let finalPath   = destinationPath + "/" + (entry.path.lastComponent ?? entry.path.string)
            try fileContent.write(to: URL(fileURLWithPath: finalPath))
            context.outputMessage("File written: \(finalPath)")
        case .noValue(let reason):
            context.outputError("File \(entry.path) has no content: \(reason)")
        case nil:
            context.outputError("File \(entry.path) has a nil value")
        }
    }
}
