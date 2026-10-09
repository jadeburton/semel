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
            guard !tokens.isEmpty else {
                throw CommandParserError.missingArgument(command: "push", expected: "pathOrWildcard")
            }
            try handlePush(externalPathsOrWildcards: tokens, context: context)

        case "rm", "remove":
            guard !tokens.isEmpty else {
                throw CommandParserError.missingArgument(command: "rm", expected: "pathOrWildcard")
            }
            try handleRemove(pathsOrWildcards: tokens, context: context)

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

    /// Several paths are one push: one batch, one work list — so a file two of them reach
    /// is sent once — and one report, which counts rather than names once the list is
    /// long. What `semel-watch` issues for a burst of saves; a path that matches nothing is
    /// reported and the rest are pushed.
    private func handlePush(externalPathsOrWildcards arguments: [String], context: any CommandContext) throws {
        let matcher = FileWildcardMatcher(input: ExternalFileSystemLister(rootDirectoryPath: context.baseDirectory))
        var entries: [FileWildcardEntry] = []
        for externalPathOrWildcard in arguments {
            // The matcher is rooted at baseDirectory, and Path drops a leading slash, so an
            // absolute path would silently be reinterpreted as relative and match nothing.
            // Say so instead of doing nothing.
            guard !externalPathOrWildcard.hasPrefix("/"), !externalPathOrWildcard.hasPrefix("~") else {
                context.outputError("push: \(externalPathOrWildcard): only paths under \(context.baseDirectory) can be pushed")
                continue
            }

            // Resolve the user-supplied wildcard relative to the internal current directory
            // so that "push *.c" from "src/a" reads baseDirectory/src/a/*.c and stores
            // the files at input:/src/a/*.c.  `resolve` also folds away "." and "..".
            let effectiveWildcard = context.resolve(externalPathOrWildcard,
                                                    relativeTo: context.currentDirectoryPath)

            let matched = try matcher.findAllMatching(pathOrWildcard: effectiveWildcard)
            guard !matched.isEmpty else {
                context.outputError("push: \(externalPathOrWildcard): no such file or directory")
                continue
            }
            entries.append(contentsOf: matched)
        }
        guard !entries.isEmpty else {
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
                context.outputError("push: \(arguments.joined(separator: " ")): a build's export folder is never pushed")
                return
            }
        }

        // One batch around the whole push, so the engine coalesces its work signals; and so
        // a push nobody wrapped in `begin` … `commit` is checked against the locks as one
        // change, and refused whole when it moves a locked folder (B-146).
        try context.inBatchOfItsOwn {
            try push(work, notOnDisk: notOnDisk, context: context)
        }
    }

    /// The pushing half of `push`: the work list sent, the outcomes reported.
    private func push(_ work: [PushWork], notOnDisk: [String], context: any CommandContext) throws {
        // A push of a whole project runs to thousands of files: name each one while the
        // list is short enough to read, and count them when it is not.
        let nameEachPath = work.count <= PathList.namedIndividually
        var files     = 0
        var folders   = 0
        var unchanged = 0

        defer { reportNotOnDisk(notOnDisk, namedIndividually: nameEachPath, context: context) }

        func report(_ entry: FileWildcardEntry, _ outcome: PushOutcome) {
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

        var batch    = PushBatch()
        var pipeline = PushPipeline()
        defer { pipeline.abandon() }
        for item in work {
            switch item {
            case .held(let entry):
                batch.append(.decided(entry, Self.heldOutcome(of: entry)))
            case .send(let entry) where entry.kind == .file:
                batch.append(PushBatch.Step(reading: entry, under: context.baseDirectory))
            case .send(let entry):
                batch.append(.folder(entry))
            }
            if batch.isFull {
                try pipeline.send(&batch, context: context, report: report)
            }
        }
        try pipeline.send(&batch, context: context, report: report)
        try pipeline.collectAll(context: context, report: report)

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

        // The roots first, for the dot-named files each folder holds: a walk of the disk
        // leaves them out, and the server's roots fold them in (B-77 item 5).
        let heldRoots = try Self.heldRoots(below: entry.path, context: context)
        var hiddenFiles: [String: [String]] = [:]
        for held in heldRoots.values.sorted(by: { $0.path < $1.path }) where !held.hiddenFiles.isEmpty {
            hiddenFiles[held.path] = held.hiddenFiles
        }
        let onDisk = FolderOnDisk.read(entry.path, under: context.baseDirectory, symbolicLinkTarget: entry.symbolicLinkTarget,
                                       hiddenFiles: hiddenFiles, excluding: isExcluded)

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

    /// How many files one push request carries, and how many of their bytes, past which the
    /// next file starts another: enough that the round trip is a small part of each file's
    /// cost, few enough that one push does not hold the server's queue, which every client
    /// takes turns on, for long at a time. The file that reaches either limit closes its
    /// request, however large it is; the frame's own limit is far above both.
    static let filesPerRequest = 64
    static let bytesPerRequest = 8 << 20

    /// How many of a push's batches may be on their way to the server at once. While the
    /// server records one, the client reads the next from disk and sends it and the server
    /// hashes it, so the queue that records them finds the next batch waiting rather than
    /// waiting for it. Measured on a cold push of 4,537 files (`BACKLOG.md`, Performance,
    /// 2026-10-04): one is barely better than none, because the next batch is read but
    /// still hashed after the one before is recorded; two takes the push from 4.0 s to
    /// 3.4 s; three is no faster than two and holds another 8 MB in flight.
    static let batchesInFlight = 2

    /// What a push sends, gathered into batches and kept in flight (`batchesInFlight`), and
    /// each batch's replies collected in the order the batches were sent. The server
    /// handles a connection's requests in arrival order, so the replies say what they would
    /// have said had the push waited for each; and a batch is reported only when it is
    /// collected, so the report keeps the work list's order however far ahead the sending
    /// has got.
    private struct PushPipeline {

        /// Oldest first.
        private var inFlight: [SentBatch] = []

        /// Sends what `batch` has gathered and leaves it empty, collecting the oldest batch
        /// first when as many as may be are already out.
        mutating func send(_ batch: inout PushBatch, context: any CommandContext,
                           report: (FileWildcardEntry, PushOutcome) -> Void) throws {
            guard !batch.isEmpty else {
                return
            }
            while inFlight.count >= FilePlugin.batchesInFlight {
                try collectOldest(context: context, report: report)
            }
            let gathered = batch
            batch = PushBatch()
            inFlight.append(try gathered.send(context: context))
        }

        /// Collects every batch still out, in order.
        mutating func collectAll(context: any CommandContext, report: (FileWildcardEntry, PushOutcome) -> Void) throws {
            while !inFlight.isEmpty {
                try collectOldest(context: context, report: report)
            }
        }

        /// Waits out every reply still to come and drops it: what a push that stopped on a
        /// failure leaves behind, so that nothing it sent is still being answered when the
        /// next command's requests go out — the batch's end among them.
        mutating func abandon() {
            for sent in inFlight {
                sent.waitForReplies()
            }
            inFlight = []
        }

        private mutating func collectOldest(context: any CommandContext,
                                            report: (FileWildcardEntry, PushOutcome) -> Void) throws {
            try inFlight.removeFirst().report(context: context, report: report)
        }
    }

    /// The files a push sends, gathered into one request (`pushFiles`) rather than one
    /// each: a request per file is a round trip per file, and the server hashes and stores
    /// the files of one request on every core before its one queue records them. What
    /// stands between them in the work list — an entry already held, a file that could not
    /// be read — waits in here too, so the report keeps the work list's order. A folder or
    /// a link is a request of its own and closes the batch, so the requests leave in the
    /// work list's order.
    private struct PushBatch {

        enum Step {
            /// Reported as it is, with no request.
            case decided(FileWildcardEntry, PushOutcome)
            /// Listed a moment ago and deleted or made unreadable since: reported, and the
            /// push goes on, as for a file the server refuses.
            case unreadable(message: String)
            case file(FileWildcardEntry, PushedContent)
            /// Just the folder. Its contents are separate entries in the work list, put
            /// there by `expand`, so that a file reachable both directly and through its
            /// folder is still pushed once.
            case folder(FileWildcardEntry)

            init(reading entry: FileWildcardEntry, under baseDirectory: String) {
                let absolutePath = (baseDirectory as NSString).appendingPathComponent(entry.path.string)
                do {
                    self = .file(entry, try PushedContent(ofFileAt: absolutePath, listedAs: entry))
                } catch {
                    self = .unreadable(message: "push: \(entry.path): \(error.localizedDescription)")
                }
            }
        }

        private var steps: [Step] = []
        private var fileCount = 0
        private var byteCount = 0
        /// A link or a folder is a request of its own, after the batch's files.
        private var endsWithOwnRequest = false

        var isEmpty: Bool { steps.isEmpty }

        var isFull: Bool {
            endsWithOwnRequest || fileCount >= FilePlugin.filesPerRequest || byteCount >= FilePlugin.bytesPerRequest
        }

        mutating func append(_ step: Step) {
            steps.append(step)
            switch step {
            case .decided, .unreadable:
                return
            case .folder:
                endsWithOwnRequest = true
            case .file(_, let content):
                guard content.symbolicLinkTarget == nil else {
                    endsWithOwnRequest = true
                    return
                }
                fileCount += 1
                byteCount += content.bytes.count
            }
        }

        /// Sends the batch's requests without waiting for their replies: its files as one,
        /// then the link or folder that closed it.
        func send(context: any CommandContext) throws -> SentBatch {
            let files = steps.compactMap { step -> (entry: FileWildcardEntry, content: PushedContent)? in
                guard case .file(let entry, let content) = step, content.symbolicLinkTarget == nil else {
                    return nil
                }
                return (entry, content)
            }
            let filesReply = try SentBatch.FilesReply(sending: files, context: context)

            let sent = try steps.map { step -> SentBatch.Step in
                switch step {
                case .decided(let entry, let outcome):
                    return .decided(entry, outcome)
                case .unreadable(let message):
                    return .unreadable(message: message)
                case .folder(let entry):
                    guard let target = entry.symbolicLinkTarget else {
                        return .folder(entry, reply: try context.requestWithoutWaiting(.pushFolder(path: entry.path.string)))
                    }
                    let request = DaemonRequest.pushSymbolicLink(path: entry.path.string, target: target, referent: .folder)
                    return .link(entry, target: target, reply: try context.requestWithoutWaiting(request))
                case .file(let entry, let content):
                    guard let target = content.symbolicLinkTarget else {
                        return .file(entry)
                    }
                    let request = DaemonRequest.pushSymbolicLink(path: entry.path.string, target: target,
                                                                 referent: .file(mode: content.mode))
                    return .link(entry, target: target,
                                 reply: try context.requestWithoutWaiting(request, body: content.bytes))
                }
            }
            return SentBatch(steps: sent, filesReply: filesReply)
        }
    }

    /// A batch on its way: its requests sent, its replies still to collect.
    private struct SentBatch {

        enum Step {
            case decided(FileWildcardEntry, PushOutcome)
            case unreadable(message: String)
            /// Answered, in turn, by the batch's `filesReply`.
            case file(FileWildcardEntry)
            case link(FileWildcardEntry, target: String, reply: PendingDaemonReply)
            case folder(FileWildcardEntry, reply: PendingDaemonReply)
        }

        /// The one request for the batch's plain files. One file goes as `pushFile`, which
        /// is all a batch of one needs; several as `pushFiles`.
        enum FilesReply {
            case none
            case one(PendingDaemonReply)
            case several(PendingDaemonReply, count: Int)

            init(sending files: [(entry: FileWildcardEntry, content: PushedContent)], context: any CommandContext) throws {
                guard files.count > 1 else {
                    guard let file = files.first else {
                        self = .none
                        return
                    }
                    let request = DaemonRequest.pushFile(path: file.entry.path.string, mode: file.content.mode)
                    self = .one(try context.requestWithoutWaiting(request, body: file.content.bytes))
                    return
                }
                let headers = files.map {
                    PushedFileHeader(path: $0.entry.path.string, mode: $0.content.mode, length: $0.content.bytes.count)
                }
                let body = PushedFiles.body(joining: files.map(\.content.bytes))
                self = .several(try context.requestWithoutWaiting(.pushFiles(files: headers), body: body),
                                count: files.count)
            }

            /// What became of each file, in order; nil for one the reply did not answer as a
            /// push, which is skipped unreported.
            func outcomes() throws -> [PushedFileOutcome?] {
                switch self {
                case .none:
                    return []
                case .one(let pending):
                    do {
                        guard case .pushFile(let didChange) = try pending.reply().0 else {
                            return [nil]
                        }
                        return [.stored(didChange: didChange)]
                    } catch let failure as ServerError where failure.isTheRequestsOwn {
                        return [.failed(error: failure.response)]
                    }
                case .several(let pending, let count):
                    let reply: DaemonResponse
                    do {
                        reply = try pending.reply().0
                    } catch let failure as ServerError where failure.isTheRequestsOwn {
                        return Array(repeating: .failed(error: failure.response), count: count)
                    }
                    guard case .pushFiles(let outcomes) = reply, outcomes.count == count else {
                        return Array(repeating: nil, count: count)
                    }
                    return outcomes
                }
            }

            fileprivate var pending: PendingDaemonReply? {
                switch self {
                case .none:                        return nil
                case .one(let pending):            return pending
                case .several(let pending, _):     return pending
                }
            }
        }

        let steps: [Step]
        let filesReply: FilesReply

        /// Collects the batch's replies and reports every step in order. A failure that is
        /// the server's rather than one entry's stops the push.
        func report(context: any CommandContext, report: (FileWildcardEntry, PushOutcome) -> Void) throws {
            var outcomes = try filesReply.outcomes()[...]
            for step in steps {
                switch step {
                case .decided(let entry, let outcome):
                    report(entry, outcome)
                case .unreadable(let message):
                    context.outputError(message)
                case .file(let entry):
                    try Self.report(outcomes.popFirst() ?? nil, of: entry, context: context, report: report)
                case .link(let entry, let target, let pending):
                    try Self.reportOwnRequest(of: entry, context: context) {
                        guard case .pushFile(let didChange) = try pending.reply().0 else {
                            return
                        }
                        report(entry, .symbolicLink(target: target, didChange: didChange))
                    }
                case .folder(let entry, let pending):
                    try Self.reportOwnRequest(of: entry, context: context) {
                        _ = try pending.reply()
                        report(entry, .folder)
                    }
                }
            }
        }

        /// Blocks until every reply has come, and drops them.
        func waitForReplies() {
            var pendings = [filesReply.pending].compactMap { $0 }
            for step in steps {
                switch step {
                case .link(_, _, let pending), .folder(_, let pending):
                    pendings.append(pending)
                case .decided, .unreadable, .file:
                    break
                }
            }
            for pending in pendings {
                _ = try? pending.reply()
            }
        }

        /// One file's outcome, said as a push says it; a failure that is not the file's own
        /// is thrown.
        private static func report(_ outcome: PushedFileOutcome?, of entry: FileWildcardEntry, context: any CommandContext,
                                   report: (FileWildcardEntry, PushOutcome) -> Void) throws {
            switch outcome {
            case .stored(let didChange):
                report(entry, .file(didChange: didChange))
            case .failed(let error):
                let failure = ServerError(response: error)
                guard failure.isTheRequestsOwn else {
                    throw failure
                }
                context.outputError("push: \(entry.path): \(failure)")
            case nil:
                break
            }
        }

        /// A link or a folder the server could not store is reported by its path and the
        /// push goes on to the next entry, as for a file that cannot be read: one entry the
        /// graph refused says nothing about the rest (B-130).
        private static func reportOwnRequest(of entry: FileWildcardEntry, context: any CommandContext,
                                             _ collect: () throws -> Void) throws {
            do {
                try collect()
            } catch let failure as ServerError where failure.isTheRequestsOwn {
                context.outputError("push: \(entry.path): \(failure)")
            }
        }
    }

    // MARK: - rm

    /// Several paths are one removal: one batch and one report, as several paths are one
    /// push. A path that matches nothing is reported and the rest are removed.
    private func handleRemove(pathsOrWildcards: [String], context: any CommandContext) throws {
        let base = context.currentDirectoryPath

        // One batch around the removal, as a push takes around its files: the server
        // unpins and marks as it walks the matches, and without a batch the engine drains
        // against a tree the walk is still taking apart.
        try context.inBatchOfItsOwn {
            try remove(pathsOrWildcards, under: base, context: context)
        }
    }

    /// The removing half of `rm`: each pattern sent, the removal reported.
    private func remove(_ pathsOrWildcards: [String], under base: Path, context: any CommandContext) throws {
        // The reply to a removal of a whole tree streams (B-137): each part is counted as it
        // comes and says how far the removal has got, and no more paths are kept than the
        // report can name.
        var removal = RemovalTally()
        for pathOrWildcard in pathsOrWildcards {
            let fullPattern: Path = base.isEmpty ? Path(pathOrWildcard) : base / pathOrWildcard
            let takenBefore = removal.count
            let (last, _) = try context.request(.remove(pattern: fullPattern.string)) { part in
                guard case .remove(let files, let folders) = part else {
                    return
                }
                removal.add(files: files, folders: folders)
                if let counts = Self.countedTogether(files: removal.fileCount, folders: removal.folderCount) {
                    context.outputMessage("Removing: \(counts) so far")
                }
            }
            guard case .remove(let files, let folders) = last else {
                continue
            }
            removal.add(files: files, folders: folders)
            if removal.count == takenBefore {
                context.outputError("rm: \(pathOrWildcard): no such file or directory")
            }
        }
        guard !removal.isEmpty else {
            return
        }

        // Naming the folders it took is also how a removal says which it did *not*: `*`
        // matches within one segment and `*.*` needs a literal dot, as in a shell, so a
        // pattern can take every file of a folder and leave the folder standing, and the
        // report then names files and no folder.
        reportRemoval(removal, context: context)
    }

    /// What one `rm` took, gathered part by part: how many of each kind, and the first
    /// paths of each, as many as a report ever names. A removal of a whole tree is
    /// counted, never held.
    struct RemovalTally {
        private(set) var fileCount   = 0
        private(set) var folderCount = 0
        private(set) var firstFiles:   [String] = []
        private(set) var firstFolders: [String] = []

        var count:   Int  { fileCount + folderCount }
        var isEmpty: Bool { fileCount + folderCount == 0 }

        mutating func add(files: [String], folders: [String]) {
            fileCount   += files.count
            folderCount += folders.count
            firstFiles.append(contentsOf: files.prefix(PathList.namedIndividually - firstFiles.count))
            firstFolders.append(contentsOf: folders.prefix(PathList.namedIndividually - firstFolders.count))
        }
    }

    // MARK: - Reporting what a verb touched

    /// What `rm` says when it succeeds: a line per path while the list is short enough to
    /// read, and a count once it is not — the folders first, since a folder is the shape of
    /// what happened and the files are what fill the screen.
    private func reportRemoval(_ removal: RemovalTally, context: any CommandContext) {
        guard removal.count > PathList.namedIndividually else {
            removal.firstFolders.forEach { context.outputMessage("Removed folder: \($0)") }
            removal.firstFiles.forEach { context.outputMessage("Removed file: \($0)") }
            return
        }
        guard let counts = Self.countedTogether(files: removal.fileCount, folders: removal.folderCount) else {
            return
        }

        var line = "Removed \(counts)"
        if removal.folderCount > 0 {
            line += ": \(Self.named(removal.firstFolders, of: removal.folderCount))"
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
        named(Array(paths.prefix(PathList.namedIndividually)), of: paths.count)
    }

    /// The same, for a list of which only the first paths were kept: `total` is how many
    /// there were.
    private static func named(_ firstPaths: [String], of total: Int) -> String {
        let named = firstPaths.prefix(PathList.namedIndividually)
        let rest  = total - named.count
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

        guard let exported = try Self.exportFiles(folderToken: folderToken, destination: destination,
                                                  skippingWithoutValue: false, context: context) else {
            return
        }
        let externalDest = ExternalPathSanitizer.expandPartialPath(destination)
        context.outputMessage("Exported \(exported) file\(exported == 1 ? "" : "s") into \(externalDest)")
    }

    /// Writes every file under `<folderToken>` of the output file system into
    /// `destination`, keeping the tree below the folder, and answers how many it wrote —
    /// nil when there was nothing to export, which it reports. With
    /// `skippingWithoutValue`, a product that has no value is passed over rather than
    /// reported: what a build with errors exports into a folder the reader named, whose
    /// report already says which products have none.
    static func exportFiles(folderToken: String, destination: String, skippingWithoutValue: Bool,
                            context: any CommandContext) throws -> Int? {
        // The folder is a path in the output file system, from its root — the same folder
        // `build` took, which named the input tree the products mirror.
        // `.` is the root itself, which is always there and which a listing cannot name:
        // every product, as a watcher of the whole base exports them (B-126).
        let folderPath = context.resolve(folderToken, relativeTo: .empty)
        if !folderPath.isEmpty {
            guard case .list(let folderMatches) = try context.request(.list(fileSystem: .output,
                                                                            pattern: folderPath.string)).0 else {
                return nil
            }
            guard folderMatches.count == 1, folderMatches[0].kind == .folder else {
                context.outputError("export: \(folderToken): no such folder in the output file system")
                return nil
            }
        }

        let treePattern = (folderPath / Path("**/*")).string
        guard case .list(let matches) = try context.request(.list(fileSystem: .output,
                                                                  pattern: treePattern)).0 else {
            return nil
        }
        // A product with a value is listed as there, or as one nothing reads: products are
        // read by nothing in the graph.
        let files = matches.filter { entry in
            entry.kind == .file && (!skippingWithoutValue || entry.status == .none || entry.status == .unreferenced)
        }
        guard !files.isEmpty else {
            if !skippingWithoutValue {
                context.outputError("export: \(folderToken): nothing to export")
            }
            return skippingWithoutValue ? 0 : nil
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
        return exported
    }

    /// Writes one exported file or link below `destinationPath`, at the place it holds
    /// below `folderPath`, creating the directories on the way. Returns whether it was
    /// written.
    private static func exportOneFile(_ entry: ListEntry, below folderPath: Path,
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
