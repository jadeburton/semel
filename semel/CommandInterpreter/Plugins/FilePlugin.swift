// FilePlugin.swift
// semel
//
// Handles: push, rm / remove, cp / copy

import Foundation
import SemelNodeKit
import SemelProtocol

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

        // One batch around the whole push, so the engine coalesces its work signals.
        _ = try context.request(.beginBatch)
        defer { _ = try? context.request(.endBatch) }

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

        guard case .folder = entry.kind else {
            return [entry]
        }

        let matcher = FileWildcardMatcher(input: ExternalFileSystemLister(rootDirectoryPath: baseDirectory))

        let contents = try matcher.findAllMatching(pathOrWildcard: entry.path.string + "/**/*")
            .filter {
                if case .file = $0.kind {
                    return true
                } else {
                    return false
                }
            }

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
            let fileContent: Data
            do {
                fileContent = try Data(contentsOf: URL(fileURLWithPath: absolutePath))
            } catch {
                context.outputError("push: \(relativePath): \(error.localizedDescription)")
                return
            }

            let mode = Self.mode(ofFileAt: absolutePath)

            guard case .pushFile(let didChange) = try context.request(.pushFile(path: relativePath.string, mode: mode),
                                                                       body: fileContent).0 else {
                return
            }
            context.outputMessage("Push file: \(relativePath) \(didChange ? "" : "[no change]")")

        case .folder:
            // Just the folder. Its contents are separate entries in the work list, put
            // there by `expand`, so that a file reachable both directly and through its
            // folder is still pushed once.
            context.outputMessage("Push folder: \(relativePath)")
            _ = try context.request(.pushFolder(path: relativePath.string))
        }
    }

    /// The file's permission bits, or the default when they cannot be read.
    private static func mode(ofFileAt absolutePath: String) -> UInt16 {
        let attributes  = try? FileManager.default.attributesOfItem(atPath: absolutePath)
        let permissions = attributes?[.posixPermissions] as? NSNumber
        return permissions.map { UInt16(truncatingIfNeeded: $0.intValue) } ?? FileMetadata.defaultMode
    }

    // MARK: - rm

    private func handleRemove(pathOrWildcard: String, context: any CommandContext) throws {
        let base = context.currentDirectoryPath
        let fullPattern: Path = base.isEmpty ? Path(pathOrWildcard) : base / pathOrWildcard

        guard case .remove(let removedPaths) = try context.request(.remove(pattern: fullPattern.string)).0 else {
            return
        }

        if removedPaths.isEmpty {
            context.outputError("rm: \(pathOrWildcard): no such file or directory")
        }
    }

    // MARK: - cp

    private func handleCopy(folder: FileSystemForCommand?, pathOrWildcard: String,
                            destinationPath: String?, context: any CommandContext) throws {
        // An explicit -i/-o names a file system the current directory does not belong
        // to, so the source pattern is root-relative in that case (same rule as `ls`).
        let targetFS   = folder ?? context.currentFileSystem
        let base: Path = folder != nil ? .empty : context.currentDirectoryPath

        // `resolve` folds away "." and "..", and treats a leading "/" as the root of
        // the internal file system.
        let fullPattern = context.resolve(pathOrWildcard, relativeTo: base)

        // The destination is an external OS path, so it follows the same rules as every
        // other external path the user types: "~" expands, relative is relative to the
        // process working directory.
        let externalDest = ExternalPathSanitizer.expandPartialPath(destinationPath ?? ".")

        guard case .list(let entries) = try context.request(.list(fileSystem: targetFS.kind, pattern: fullPattern.string)).0 else {
            return
        }

        guard !entries.isEmpty else {
            context.outputError("cp: \(pathOrWildcard): no such file or directory")
            return
        }

        for entry in entries where entry.kind == .file {
            do {
                try copyOneFile(entry, from: targetFS, destinationPath: externalDest, context: context)
            } catch {
                context.outputError("cp: \(entry.path): \(error)")
            }
        }
    }

    private func copyOneFile(_ entry: ListEntry, from fileSystem: FileSystemForCommand,
                             destinationPath: String, context: any CommandContext) throws {
        let (response, body) = try context.request(.fetch(fileSystem: fileSystem.kind, path: entry.path))

        guard case .fetch(let mode) = response else {
            context.outputError("File \(entry.path) has no content")
            return
        }
        let bytes = body ?? Data()

        let path      = Path(entry.path)
        let finalPath = destinationPath + "/" + (path.lastComponent ?? path.string)
        try bytes.write(to: URL(fileURLWithPath: finalPath))
        chmod(finalPath, mode_t(mode))
        context.outputMessage("File written: \(finalPath)")
    }
}
