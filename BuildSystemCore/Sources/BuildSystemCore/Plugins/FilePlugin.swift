// FilePlugin.swift
// build_system
//
// Handles: push, rm, cp

import Foundation

final class FilePlugin: CommandPlugin {

    func handle(_ command: UserCommand, context: any CommandContext) throws -> Bool {
        switch command {
        case .push(let p):               try handlePush(externalPathOrWildcard: p, context: context)
        case .remove(let p):             try handleRemove(pathOrWildcard: p, context: context)
        case .copy(let f, let p, let d): try handleCopy(folder: f, pathOrWildcard: p, destinationPath: d, context: context)
        default: return false
        }
        return true
    }

    // MARK: - push

    private func handlePush(externalPathOrWildcard: String, context: any CommandContext) throws {
        guard let baseDirectory = context.baseDirectory else {
            context.outputError("Set a base directory before pushing files"); return
        }
        let matcher = FileWildcardMatcher(input: ExternalFileSystemLister(rootDirectoryPath: baseDirectory))
        try matcher.findAllMatching(pathOrWildcard: externalPathOrWildcard).forEach { entry in
            try pushOne(entry, baseDirectory: baseDirectory, context: context)
        }
    }

    private func pushOne(_ entry: FileWildcardEntry, baseDirectory: String, context: any CommandContext) throws {
        let relativePath = entry.path
        context.outputMessage("Push: \(relativePath)")

        switch entry.kind {
        case .file:
            let absolutePath = (baseDirectory as NSString).appendingPathComponent(relativePath.string)
            let fileContent  = try! [UInt8](Data(contentsOf: URL(fileURLWithPath: absolutePath)))

            _ = try context.inputFileSystem.ensureEntirePathExistsAsFolders(
                    relativePath.deletingLastComponent ?? .empty, pinned: true)

            let pathIncludingInputFileSystem = Path("inputFileSystem") / relativePath
            let graphShapeNode = try GraphShapeNode.parse("StaticFile(path: '\(pathIncludingInputFileSystem.string)')")
            let (fromNode, _) = try graphShapeNode.findOrCreateMatchingNode()
            _ = try (fromNode.nodeFunctionCast() as StaticFile).replaceContent(fileContent.intern())

        case .folder:
            _ = try context.inputFileSystem.ensureEntirePathExistsAsFolders(relativePath, pinned: true)
        }
    }

    // MARK: - rm

    private func handleRemove(pathOrWildcard: String, context: any CommandContext) throws {
        let matcher = FileWildcardMatcher(input: InternalFileSystemLister(folder: try context.inputFileSystem))
        try matcher.findAllMatching(pathOrWildcard: pathOrWildcard).forEach { entry in
            try removeOne(entry, context: context)
        }
    }

    private func removeOne(_ entry: FileWildcardEntry, context: any CommandContext) throws {
        guard let child = try context.inputFileSystem.childNode(path: entry.path) else {
            context.outputError("Child not found: \(entry.path)"); return
        }
        guard let userDeletableChild = try child.nodeFunction() as? UserDeletable else {
            context.outputError("Child not deletable: \(entry.path)"); return
        }
        try userDeletableChild.deleteInInputFileSystem()
    }

    // MARK: - cp

    private func handleCopy(folder: FileSystemForCommand, pathOrWildcard: String,
                             destinationPath: String?, context: any CommandContext) throws {
        let fileSystem = try context.fileSystem(for: folder)
        let matcher    = FileWildcardMatcher(input: InternalFileSystemLister(folder: fileSystem))
        try matcher.findAllMatching(pathOrWildcard: pathOrWildcard).forEach { entry in
            try? copyOneFile(folder: fileSystem, entry: entry,
                             destinationPath: destinationPath ?? ".", context: context)
        }
    }

    private func copyOneFile(folder: Node, entry: FileWildcardEntry,
                              destinationPath: String, context: any CommandContext) throws {
        guard case .file = entry.kind else { return }

        guard let fileNode = try folder.childNode(path: entry.path) else {
            context.outputError("File \(entry.path) not found in internal file system"); return
        }
        guard let file = try fileNode.nodeFunction() as? FileType else {
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
