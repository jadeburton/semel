// FilePlugin.swift
// semel
//
// Handles: push, rm / remove, cp / copy, export

import Foundation
import SemelNodeKit
import SemelProtocol

final class FilePlugin: CommandPlugin {

    let verbs: Set<String> = ["push", "rm", "remove", "cp", "copy", "export"]

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

        case "export":
            try handleExport(tokens: tokens, context: context)

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

        // Where a build exported its products is not a source, however the tree above it
        // is pushed. Named only when it was all the push asked for: a push of the tree
        // leaves it out without comment.
        let exclusions = context.pushExclusions
        let excluded = work.filter { entry in
            exclusions.contains { entry.path.string == $0 || entry.path.string.hasPrefix($0 + "/") }
        }
        if !excluded.isEmpty {
            work.removeAll { entry in excluded.contains { $0.path == entry.path } }
            if work.isEmpty {
                context.outputError("push: \(externalPathOrWildcard): a build's export folder is never pushed")
                return
            }
        }

        // One batch around the whole push, so the engine coalesces its work signals.
        _ = try context.request(.beginBatch)
        defer { _ = try? context.request(.endBatch) }

        // A push of a whole project runs to thousands of files: name each one while the
        // list is short enough to read, and count them when it is not.
        let nameEachPath = work.count <= PathList.namedIndividually
        var files     = 0
        var folders   = 0
        var unchanged = 0

        for entry in work {
            guard let outcome = try pushOne(entry, baseDirectory: context.baseDirectory, context: context) else {
                continue
            }
            switch outcome {

            case .folder:
                folders += 1
                if nameEachPath {
                    context.outputMessage("Push folder: \(entry.path)")
                }

            case .file(let didChange):
                files += 1
                if !didChange {
                    unchanged += 1
                }
                if nameEachPath {
                    context.outputMessage("Push file: \(entry.path)\(didChange ? "" : " [no change]")")
                }
            }
        }

        guard !nameEachPath, let counts = Self.countedTogether(files: files, folders: folders) else {
            return
        }
        context.outputMessage("Pushed \(counts)" + (unchanged > 0 ? ", \(unchanged) unchanged" : ""))
    }

    /// What pushing one entry did, for the report the whole push makes at the end.
    private enum PushOutcome {
        case file(didChange: Bool)
        case folder
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

    /// Pushes one entry and says what it was; `nil` when it was reported and skipped.
    private func pushOne(_ entry: FileWildcardEntry, baseDirectory: String,
                         context: any CommandContext) throws -> PushOutcome? {

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
                return nil
            }

            let mode = Self.mode(ofFileAt: absolutePath)

            guard case .pushFile(let didChange) = try context.request(.pushFile(path: relativePath.string, mode: mode),
                                                                       body: fileContent).0 else {
                return nil
            }
            return .file(didChange: didChange)

        case .folder:
            // Just the folder. Its contents are separate entries in the work list, put
            // there by `expand`, so that a file reachable both directly and through its
            // folder is still pushed once.
            _ = try context.request(.pushFolder(path: relativePath.string))
            return .folder
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

        // One batch around the removal, as a push takes around its files: the server
        // unpins and marks as it walks the matches, and without a batch the engine drains
        // against a tree the walk is still taking apart.
        _ = try context.request(.beginBatch)
        defer { _ = try? context.request(.endBatch) }

        guard case .remove(let removedFiles, let removedFolders)
                = try context.request(.remove(pattern: fullPattern.string)).0 else {
            return
        }

        guard !removedFiles.isEmpty || !removedFolders.isEmpty else {
            context.outputError("rm: \(pathOrWildcard): no such file or directory")
            return
        }

        // Naming the folders it took is also how a removal says which it did *not*: `*`
        // matches within one segment and `*.*` needs a literal dot, as in a shell, so a
        // pattern can take every file of a folder and leave the folder standing, and the
        // report then names files and no folder.
        reportRemoval(files: removedFiles, folders: removedFolders, context: context)
    }

    // MARK: - Reporting what a verb touched

    /// What `rm` says when it succeeds: a line per path while the list is short enough to
    /// read, and a count once it is not — the folders first, since a folder is the shape of
    /// what happened and the files are what fill the screen.
    private func reportRemoval(files: [String], folders: [String], context: any CommandContext) {
        guard files.count + folders.count > PathList.namedIndividually else {
            folders.forEach { context.outputMessage("Removed folder: \($0)") }
            files.forEach { context.outputMessage("Removed file: \($0)") }
            return
        }
        guard let counts = Self.countedTogether(files: files.count, folders: folders.count) else {
            return
        }

        var line = "Removed \(counts)"
        if !folders.isEmpty {
            line += ": \(Self.named(folders))"
        }
        context.outputMessage(line)
    }

    /// "12 files and 3 folders", leaving out whichever of the two is none, and nothing at
    /// all when both are.
    private static func countedTogether(files: Int, folders: Int) -> String? {
        var parts: [String] = []
        if files > 0 {
            parts.append(counted(files, "file"))
        }
        if folders > 0 {
            parts.append(counted(folders, "folder"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " and ")
    }

    /// Names paths up to the count a short list prints in full, and says how many it left
    /// out: a wildcard can match folders by the hundred, and a line naming all of them is
    /// the wall of text the count exists to replace.
    private static func named(_ paths: [String]) -> String {
        let named = paths.prefix(PathList.namedIndividually)
        let rest  = paths.count - named.count
        return named.joined(separator: ", ") + (rest > 0 ? ", and \(rest) more" : "")
    }

    private static func counted(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
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

    // MARK: - export

    /// `export <folder> --into <dir>`: every file under `<folder>` of the output file system
    /// — the products the builders there published — lands in `<dir>`, keeping the tree
    /// below `<folder>`. `cp -o` does one file at a time; this is the last step of the
    /// clone-to-build loop, so it takes the folder the build took.
    private func handleExport(tokens: [String], context: any CommandContext) throws {
        var folderToken: String?
        var destination: String?
        var index = 0
        while index < tokens.count {
            switch tokens[index] {
            case "--into":
                guard index + 1 < tokens.count else {
                    throw CommandParserError.missingArgument(command: "export", expected: "--into <dir>")
                }
                destination = tokens[index + 1]
                index += 2
            default:
                guard folderToken == nil else {
                    throw CommandParserError.tooManyArguments(command: "export")
                }
                folderToken = tokens[index]
                index += 1
            }
        }
        guard let folderToken, let destination else {
            throw CommandParserError.missingArgument(command: "export", expected: "<folder> --into <dir>")
        }

        // The folder is a path in the output file system, from its root — the same folder
        // `build` took, which named the input tree the products mirror.
        let folderPath = context.resolve(folderToken, relativeTo: .empty)
        guard case .list(let folderMatches) = try context.request(.list(fileSystem: .output,
                                                                        pattern: folderPath.string)).0 else {
            return
        }
        guard folderMatches.count == 1, folderMatches[0].kind == .folder else {
            context.outputError("export: \(folderToken): no such folder in the output file system")
            return
        }

        let treePattern = (folderPath / Path("**/*")).string
        guard case .list(let matches) = try context.request(.list(fileSystem: .output,
                                                                  pattern: treePattern)).0 else {
            return
        }
        let files = matches.filter { $0.kind == .file }
        guard !files.isEmpty else {
            context.outputError("export: \(folderToken): nothing to export")
            return
        }

        let externalDest = ExternalPathSanitizer.expandPartialPath(destination)
        var exported = 0
        for entry in files {
            do {
                if try exportOneFile(entry, below: folderPath, destinationPath: externalDest, context: context) {
                    exported += 1
                }
            } catch {
                // A product nothing has built yet has no content, and the server says so.
                // Report it and carry on, exactly as `cp` does.
                context.outputError("export: \(entry.path): \(error)")
            }
        }
        context.outputMessage("Exported \(exported) file\(exported == 1 ? "" : "s") into \(externalDest)")
    }

    /// Writes one exported file below `destinationPath`, at the place it holds below
    /// `folderPath`, creating the directories on the way. Returns whether it was written.
    private func exportOneFile(_ entry: ListEntry, below folderPath: Path,
                               destinationPath: String, context: any CommandContext) throws -> Bool {
        let (response, body) = try context.request(.fetch(fileSystem: .output, path: entry.path))
        guard case .fetch(let mode) = response else {
            context.outputError("export: \(entry.path): not a file")
            return false
        }

        let relative  = Path(entry.path).relative(to: folderPath)?.string ?? entry.path
        let finalPath = destinationPath + "/" + relative

        try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: finalPath).deletingLastPathComponent(),
                withIntermediateDirectories: true)
        try (body ?? Data()).write(to: URL(fileURLWithPath: finalPath))
        chmod(finalPath, mode_t(mode))
        return true
    }
}
