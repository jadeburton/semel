// FilePlugin.swift
// build_system
//
// Handles: push, rm / remove, cp / copy

import SemelCore
import Foundation
import SemelNodeKit

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
            let (folder, remaining) = parseOptionalFileSystemFlag(tokens: tokens)
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
        context.buildEngine.beginBatch()
        defer { context.buildEngine.endBatch() }

        // The matcher is rooted at baseDirectory, and Path drops a leading slash, so an
        // absolute path would silently be reinterpreted as relative and match nothing.
        // Say so instead of doing nothing.
        guard !externalPathOrWildcard.hasPrefix("/"), !externalPathOrWildcard.hasPrefix("~") else {
            context.outputError("push: \(externalPathOrWildcard): only paths under \(context.baseDirectory) can be pushed")
            return
        }

        // Resolve the user-supplied wildcard relative to the internal current directory
        // so that "push *.c" from "src/a" reads baseDirectory/src/a/*.c and stores
        // the files at input:/src/a/*.c.  `resolve` also folds away "." and "..".
        let effectiveWildcard = context.resolve(externalPathOrWildcard,
                                                relativeTo: context.currentDirectoryPath)

        let matcher = FileWildcardMatcher(input: ExternalFileSystemLister(rootDirectoryPath: context.baseDirectory))
        let entries = try matcher.findAllMatching(pathOrWildcard: effectiveWildcard)

        guard !entries.isEmpty else {
            context.outputError("push: \(externalPathOrWildcard): no such file or directory")
            return
        }

        // Decide the whole work list before pushing any of it, so a file that is matched
        // twice is still pushed once. A wildcard reaching into subdirectories matches a
        // directory *and* the files inside it, and pushing a directory means pushing its
        // contents — so both readings arrive at the same file. Pushing as we matched would
        // report the second arrival as "[no change]" against a file nothing had changed,
        // which makes the report describe the matching rather than what happened.
        var alreadyQueued = Set<String>()
        var work: [FileWildcardEntry] = []
        for entry in entries {
            for expanded in try expand(entry, baseDirectory: context.baseDirectory) {
                if alreadyQueued.insert(expanded.path.string).inserted {
                    work.append(expanded)
                }
            }
        }

        try work.forEach { entry in
            try pushOne(entry, baseDirectory: context.baseDirectory, context: context)
        }
    }

    /// A matched entry, plus everything pushing it implies.
    ///
    /// A directory stands for itself and every file beneath it: a bare `push src` has no
    /// wildcard enumerating its contents, so without this it would create an empty folder.
    private func expand(_ entry: FileWildcardEntry,
                        baseDirectory: String) throws -> [FileWildcardEntry] {
        guard case .folder = entry.kind else { return [entry] }

        let matcher = FileWildcardMatcher(input: ExternalFileSystemLister(rootDirectoryPath: baseDirectory))
        let contents = try matcher.findAllMatching(pathOrWildcard: entry.path.string + "/**/*")
            .filter { if case .file = $0.kind { return true } else { return false } }
        return [entry] + contents
    }

    private func pushOne(_ entry: FileWildcardEntry, baseDirectory: String,
                          context: any CommandContext) throws {
        let relativePath = entry.path

        switch entry.kind {
        case .file:
            let absolutePath = (baseDirectory as NSString).appendingPathComponent(relativePath.string)

            // The matcher listed this file a moment ago, but it can be deleted or made
            // unreadable in between — that is a report-and-continue, not a crash.
            let fileContent: [UInt8]
            do {
                fileContent = try [UInt8](Data(contentsOf: URL(fileURLWithPath: absolutePath)))
            } catch {
                context.outputError("push: \(relativePath): \(error.localizedDescription)")
                return
            }

            _ = try context.inputFileSystem.ensureEntirePathExistsAsFolders(
                    relativePath.deletingLastComponent ?? .empty, pinned: true)

            let fullPath      = Path(Folder.inputFileSystemName) / relativePath
            let graphShapeNode = try GraphShapeNode.parse("StaticFile(path: '\(fullPath.string)')")
            let (fromNode, _) = try graphShapeNode.findOrCreateMatchingNode()

            guard let staticFile = try fromNode.nodeAsAny() as? StaticFile else {
                context.outputError("push: \(relativePath): the graph holds a non-file node at this path")
                return
            }

            let didChange = try staticFile.replaceContent(fileContent.intern())

            context.outputMessage("Push file: \(relativePath) \(didChange ? "" : "[no change]")")

        case .folder:
            // Just the folder. Its contents are separate entries in the work list, put
            // there by `expand`, so that a file reachable both directly and through its
            // folder is still pushed once.
            context.outputMessage("Push folder: \(relativePath)")
            _ = try context.inputFileSystem.ensureEntirePathExistsAsFolders(relativePath, pinned: true)
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

    private func handleCopy(folder: FileSystemForCommand?, pathOrWildcard: String,
                             destinationPath: String?, context: any CommandContext) throws {
        // An explicit -i/-o names a file system the current directory does not belong
        // to, so the source pattern is root-relative in that case (same rule as `ls`).
        let targetFS   = folder ?? context.currentFileSystem
        let base: Path = folder != nil ? .empty : context.currentDirectoryPath

        let fileSystem = try context.fileSystem(for: targetFS)
        let matcher    = FileWildcardMatcher(input: InternalFileSystemLister(folder: fileSystem))

        // `resolve` folds away "." and "..", and treats a leading "/" as the root of
        // the internal file system.
        let fullPattern = context.resolve(pathOrWildcard, relativeTo: base)

        // The destination is an external OS path, so it follows the same rules as every
        // other external path the user types: "~" expands, relative is relative to the
        // process working directory.
        let externalDest = ExternalPathSanitizer.expandPartialPath(destinationPath ?? ".")

        let entries = try matcher.findAllMatching(pathOrWildcard: fullPattern)

        guard !entries.isEmpty else {
            context.outputError("cp: \(pathOrWildcard): no such file or directory")
            return
        }

        for entry in entries {
            do {
                try copyOneFile(folder: fileSystem, entry: entry,
                                destinationPath: externalDest, context: context)
            } catch {
                context.outputError("cp: \(entry.path): \(error)")
            }
        }
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
            if let metadataProvider = try fileNode.nodeAsAny() as? FileMetadataProvider,
               let metadata = try metadataProvider.readFileMetadata() {
                chmod(finalPath, mode_t(metadata.mode ?? FileMetadata.defaultMode))
            }
            context.outputMessage("File written: \(finalPath)")
        case .noValue(let reason):
            context.outputError("File \(entry.path) has no content: \(reason)")
        case nil:
            context.outputError("File \(entry.path) has a nil value")
        }
    }
}
