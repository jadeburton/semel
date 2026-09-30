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

        // Where a build exported its products is not a source, however the tree above it
        // is pushed. Named only when it was all the push asked for: a push of the tree
        // leaves it out without comment.
        let exclusions = context.pushExclusions
        let isExcluded = { (path: Path) in
            exclusions.contains { path.string == $0 || path.string.hasPrefix($0 + "/") }
        }

        // Decide the whole work list before pushing any of it, so a file that is matched
        // twice is still pushed once. A wildcard reaching into subdirectories matches a
        // directory *and* the files inside it, and pushing a directory means pushing its
        // contents — so both readings arrive at the same file. Pushing as we matched would
        // report the second arrival as "[no change]" against a file nothing had changed,
        // which makes the report describe the matching rather than what happened.
        var alreadyQueued = Set<String>()
        var work: [PushWork] = []
        var notOnDisk: [String] = []
        var comparedFolders: [Path] = []
        for entry in entries {
            // A folder inside one already compared was queued with it: comparing it again
            // would only ask the server the same question about part of the same tree.
            let covered = comparedFolders.contains { entry.path.segments.starts(with: $0.segments) }
            guard !covered else {
                continue
            }
            let plan = try expand(entry, excluding: isExcluded, context: context)
            if case .folder = entry.kind {
                comparedFolders.append(entry.path)
            }
            notOnDisk.append(contentsOf: plan.notOnDisk)
            for item in plan.work where alreadyQueued.insert(item.entry.path.string).inserted {
                work.append(item)
            }
        }

        let excluded = work.filter { isExcluded($0.entry.path) }
        if !excluded.isEmpty {
            work.removeAll { isExcluded($0.entry.path) }
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

        defer { reportNotOnDisk(notOnDisk, namedIndividually: nameEachPath, context: context) }

        for item in work {
            let entry = item.entry
            let outcome: PushOutcome
            switch item {
            case .held:
                outcome = Self.heldOutcome(of: entry)
            case .send:
                guard let sent = try pushOne(entry, baseDirectory: context.baseDirectory, context: context) else {
                    continue
                }
                outcome = sent
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

            // Counted with the files, whether it names a file or a folder: it is one entry
            // of a tree, as a file is.
            case .symbolicLink(let target, let didChange):
                files += 1
                if !didChange {
                    unchanged += 1
                }
                if nameEachPath {
                    context.outputMessage("Push link: \(entry.path) -> \(target)\(didChange ? "" : " [no change]")")
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
        case symbolicLink(target: String, didChange: Bool)
        case folder
    }

    /// One entry of a push's work list: one to send, or one the server already holds as the
    /// disk has it, which is reported as a push that changed nothing and costs no request.
    private enum PushWork {
        case send(FileWildcardEntry)
        case held(FileWildcardEntry)

        var entry: FileWildcardEntry {
            switch self {
            case .send(let entry), .held(let entry): return entry
            }
        }
    }

    /// What a push reports for an entry it did not send: what it would have reported had
    /// the server answered that nothing changed.
    private static func heldOutcome(of entry: FileWildcardEntry) -> PushOutcome {
        if let target = entry.symbolicLinkTarget {
            return .symbolicLink(target: target, didChange: false)
        }
        switch entry.kind {
        case .file:   return .file(didChange: false)
        case .folder: return .folder
        }
    }

    /// A matched entry, plus everything pushing it implies, and what the server holds below
    /// it that the disk does not.
    ///
    /// A directory stands for itself and every file beneath it: a bare `push src` has no
    /// wildcard enumerating its contents, so without this it would create an empty folder.
    /// And for every folder beneath it that is a symbolic link pushed as one, since a push
    /// makes the other folders only on the way to a file, and a link is more than that
    /// (B-77).
    ///
    /// Only what differs is sent (B-132). The disk is folded as the engine folds what it
    /// holds (`FolderOnDisk`), and the server is asked for the roots of the folder and every
    /// folder below it — one request, whatever the tree's size. A subtree whose root agrees
    /// is held already, file for file, and nothing in it is sent; a folder whose root does
    /// not is asked for its children — one request for all such folders — and only a file
    /// whose hash, mode or link target differs, or that the server lacks, is sent. Where
    /// the server holds no folder at all, everything below is sent, as a push always did.
    private func expand(_ entry: FileWildcardEntry, excluding isExcluded: (Path) -> Bool,
                        context: any CommandContext) throws -> (work: [PushWork], notOnDisk: [String]) {

        guard case .folder = entry.kind else {
            return ([.send(entry)], [])
        }

        let onDisk = FolderOnDisk.read(entry.path, under: context.baseDirectory,
                                       symbolicLinkTarget: entry.symbolicLinkTarget, excluding: isExcluded)
        let heldRoots = try Self.heldRoots(below: entry.path, context: context)

        // The folder itself: a link is always sent, since what it holds is compared in the
        // folder above it, which this push was not asked about; any other folder only when
        // the server does not hold it pinned.
        var work: [PushWork] = []
        if entry.symbolicLinkTarget == nil, heldRoots[entry.path.string]?.isPinned == true {
            work.append(.held(entry))
        } else {
            work.append(.send(entry))
        }

        var decisions: [String: FolderComparison] = [:]
        Self.compare(onDisk, with: heldRoots, into: &decisions)

        let compared = decisions.filter { $0.value == .compareChildren }.keys.sorted()
        let heldChildren = compared.isEmpty ? [:] : try Self.heldChildren(of: compared, context: context)

        var notOnDisk: [String] = []
        Self.plan(onDisk, decisions: decisions, heldChildren: heldChildren, into: &work, notOnDisk: &notOnDisk)
        return (work, notOnDisk)
    }

    /// What a push does with one folder on disk, decided from its root before any child of
    /// it is looked at.
    private enum FolderComparison: Equatable {
        /// The server holds no folder here: everything below is sent.
        case absent
        /// The server holds it pinned under the same root: nothing below is sent.
        case held
        /// The roots differ, or the server cannot vouch for its own: the children are
        /// compared one by one, and the subfolders by their own roots.
        case compareChildren
        /// As `compareChildren`, for a folder the server holds unpinned: pushed first, to
        /// pin it as a push always leaves a folder.
        case compareChildrenAndPin
    }

    /// Decides every folder from the top down, stopping at a root that agrees or a folder
    /// the server lacks: what is below either is decided by it.
    private static func compare(_ folder: FolderOnDisk, with heldRoots: [String: HeldFolderRoot],
                                into decisions: inout [String: FolderComparison]) {
        guard let held = heldRoots[folder.path.string] else {
            decisions[folder.path.string] = .absent
            return
        }
        if held.isPinned, let root = held.contentRoot, root == folder.contentRoot {
            decisions[folder.path.string] = .held
            return
        }
        decisions[folder.path.string] = held.isPinned ? .compareChildren : .compareChildrenAndPin
        for case .folder(let subfolder) in folder.children {
            compare(subfolder, with: heldRoots, into: &decisions)
        }
    }

    /// The work below `folder`, in the order a push has always sent it — what is directly
    /// in a folder by name, then each subfolder's — so that a push that sends everything
    /// sends it exactly as before (`FolderOnDisk.entriesToPush`).
    private static func plan(_ folder: FolderOnDisk, decisions: [String: FolderComparison],
                             heldChildren: [String: [String: HeldChild]],
                             into work: inout [PushWork], notOnDisk: inout [String]) {
        let decision = decisions[folder.path.string] ?? .absent
        switch decision {
        case .absent:
            work.append(contentsOf: folder.entriesToPush.map(PushWork.send))
            return
        case .held:
            work.append(contentsOf: folder.entriesToPush.map(PushWork.held))
            return
        case .compareChildren, .compareChildrenAndPin:
            break
        }

        // A folder the server has taken away since it answered is one it lacks.
        let held = heldChildren[folder.path.string] ?? [:]
        var onDiskNames = Set<String>()

        for child in folder.children {
            switch child {
            case .file(let file):
                let name = file.path.lastComponent ?? ""
                onDiskNames.insert(name)
                work.append(isHeld(file, as: held[name]) ? .held(file.entry) : .send(file.entry))

            case .folder(let subfolder):
                let name = subfolder.path.lastComponent ?? ""
                onDiskNames.insert(name)
                guard let linkEntry = subfolder.linkEntry else {
                    continue
                }
                let heldLink = held[name]
                let isHeldLink = heldLink?.kind == .folder && heldLink?.isPinned == true
                              && heldLink?.symbolicLinkTarget == linkEntry.symbolicLinkTarget
                work.append(isHeldLink ? .held(linkEntry) : .send(linkEntry))
            }
        }

        // What a push leaves and the disk no longer has: a file holding a value, a folder
        // pinned. A push only adds, so these stay; a name the graph merely asks for is not
        // the user's to be told about.
        for (name, child) in held.sorted(by: { $0.key < $1.key }) where child.isPinned && !onDiskNames.contains(name) {
            let path = (folder.path / name).string
            notOnDisk.append(child.kind == .folder ? path + "/" : path)
        }

        for case .folder(let subfolder) in folder.children {
            if subfolder.symbolicLinkTarget == nil, decisions[subfolder.path.string] == .compareChildrenAndPin {
                work.append(.send(FileWildcardEntry(path: subfolder.path, kind: .folder, state: nil, isUnreferenced: false)))
            }
            plan(subfolder, decisions: decisions, heldChildren: heldChildren, into: &work, notOnDisk: &notOnDisk)
        }
    }

    /// Whether the server holds `file` as the disk has it: the same bytes, mode and link.
    private static func isHeld(_ file: FileOnDisk, as held: HeldChild?) -> Bool {
        guard let held, held.kind == .file, let heldHash = held.contentHash,
              held.mode == file.mode, held.symbolicLinkTarget == file.symbolicLinkTarget else {
            return false
        }
        // A link's bytes are what it names, which the fold does not read: read them only
        // here, where its folder's root has already said something below it differs.
        let hash = file.symbolicLinkTarget == nil ? file.contentHash : file.contentHashFollowingLinks()
        return hash == heldHash
    }

    /// The roots the server holds for `path` and every folder below it, by path. None when
    /// the server does not answer with roots, which is read as a server holding nothing:
    /// everything is then sent, as a push always did.
    private static func heldRoots(below path: Path, context: any CommandContext) throws -> [String: HeldFolderRoot] {
        let (response, body) = try context.request(.contentRoots(path: path.string))
        guard case .contentRoots = response, let body else {
            return [:]
        }
        let roots = try MessageCoder.decode([HeldFolderRoot].self, from: body)
        return Dictionary(roots.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The children the server holds in each folder at `paths`, by folder path and then by
    /// name.
    private static func heldChildren(of paths: [String], context: any CommandContext) throws -> [String: [String: HeldChild]] {
        let (response, body) = try context.request(.folderChildren(paths: paths))
        guard case .folderChildren = response, let body else {
            return [:]
        }
        var result: [String: [String: HeldChild]] = [:]
        for folder in try MessageCoder.decode([HeldFolder].self, from: body) {
            result[folder.path] = Dictionary(folder.children.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        }
        return result
    }

    /// Says what the server holds that the disk does not. Not an error: `push` only adds,
    /// and a file deleted on disk stays in the graph until `rm` takes it — which is worth
    /// saying, since a build goes on reading it.
    private func reportNotOnDisk(_ paths: [String], namedIndividually: Bool, context: any CommandContext) {
        guard !paths.isEmpty else {
            return
        }
        guard !namedIndividually || paths.count > PathList.namedIndividually else {
            paths.forEach { context.outputMessage("Not on disk, kept: \($0) (push only adds; rm removes it)") }
            return
        }
        let folders = paths.filter { $0.hasSuffix("/") }.count
        guard let counts = Self.countedTogether(files: paths.count - folders, folders: folders) else {
            return
        }
        context.outputMessage("Not on disk, kept: \(counts) (push only adds; rm removes them): \(Self.named(paths))")
    }

    /// Pushes one entry and says what it was; `nil` when it was reported and skipped.
    private func pushOne(_ entry: FileWildcardEntry, baseDirectory: String,
                         context: any CommandContext) throws -> PushOutcome? {

        let relativePath = entry.path

        if case .folder = entry.kind {
            // Just the folder. Its contents are separate entries in the work list, put
            // there by `expand`, so that a file reachable both directly and through its
            // folder is still pushed once.
            guard let target = entry.symbolicLinkTarget else {
                _ = try context.request(.pushFolder(path: relativePath.string))
                return .folder
            }
            let request = DaemonRequest.pushSymbolicLink(path: relativePath.string, target: target, referent: .folder)
            guard case .pushFile(let didChange) = try context.request(request).0 else {
                return nil
            }
            return .symbolicLink(target: target, didChange: didChange)
        }

        let absolutePath = (baseDirectory as NSString).appendingPathComponent(relativePath.string)

        // The matcher listed this file a moment ago, but it can be deleted or made
        // unreadable in between — that is a report-and-continue, not a crash.
        let content: PushedContent
        do {
            content = try PushedContent(ofFileAt: absolutePath, listedAs: entry)
        } catch {
            context.outputError("push: \(relativePath): \(error.localizedDescription)")
            return nil
        }

        guard let target = content.symbolicLinkTarget else {
            guard case .pushFile(let didChange) = try context.request(.pushFile(path: relativePath.string, mode: content.mode),
                                                                       body: content.bytes).0 else {
                return nil
            }
            return .file(didChange: didChange)
        }
        let request = DaemonRequest.pushSymbolicLink(path: relativePath.string, target: target, referent: .file(mode: content.mode))
        guard case .pushFile(let didChange) = try context.request(request, body: content.bytes).0 else {
            return nil
        }
        return .symbolicLink(target: target, didChange: didChange)
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

        let path      = Path(entry.path)
        let finalPath = destinationPath + "/" + (path.lastComponent ?? path.string)
        switch response {
        case .fetch(let mode):
            try (body ?? Data()).write(to: URL(fileURLWithPath: finalPath))
            chmod(finalPath, mode_t(mode))
            context.outputMessage("File written: \(finalPath)")
        case .symbolicLink(let target):
            try Self.writeSymbolicLink(at: finalPath, target: target)
            context.outputMessage("Link written: \(finalPath) -> \(target)")
        default:
            context.outputError("File \(entry.path) has no content")
        }
    }

    /// A link at `path` to `target`, replacing whatever is there — a file, a folder an
    /// earlier export left, another link — without following it.
    private static func writeSymbolicLink(at path: String, target: String) throws {
        try removeWithoutFollowing(path)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
    }

    /// Removes what is at `path`, a link itself and never what it names. `attributesOfItem`
    /// does not follow a link, where `fileExists` would, and would miss one naming nothing.
    private static func removeWithoutFollowing(_ path: String) throws {
        guard (try? FileManager.default.attributesOfItem(atPath: path)) != nil else {
            return
        }
        try FileManager.default.removeItem(atPath: path)
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

    /// Writes one exported file or link below `destinationPath`, at the place it holds
    /// below `folderPath`, creating the directories on the way. Returns whether it was
    /// written.
    private func exportOneFile(_ entry: ListEntry, below folderPath: Path,
                               destinationPath: String, context: any CommandContext) throws -> Bool {
        let (response, body) = try context.request(.fetch(fileSystem: .output, path: entry.path))

        let relative  = Path(entry.path).relative(to: folderPath)?.string ?? entry.path
        let finalPath = destinationPath + "/" + relative

        switch response {
        case .fetch(let mode):
            try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: finalPath).deletingLastPathComponent(),
                    withIntermediateDirectories: true)
            // What an earlier export left is replaced, whatever mode it was left with: a
            // vendored resource arrives read-only and leaves read-only (B-108), and a write
            // over it would be refused, so a second `build --into` the same folder failed on
            // every such file (B-125).
            try Self.removeWithoutFollowing(finalPath)
            try (body ?? Data()).write(to: URL(fileURLWithPath: finalPath))
            chmod(finalPath, mode_t(mode))
            return true

        // A link is written as the link: a versioned framework's `Versions/Current` and the
        // links at its top are what makes its signature verify (B-77). No mode: a link's is
        // not read.
        case .symbolicLink(let target):
            try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: finalPath).deletingLastPathComponent(),
                    withIntermediateDirectories: true)
            try Self.writeSymbolicLink(at: finalPath, target: target)
            return true

        default:
            context.outputError("export: \(entry.path): not a file")
            return false
        }
    }
}
