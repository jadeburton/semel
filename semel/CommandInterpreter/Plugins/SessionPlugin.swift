// SessionPlugin.swift
// semel
//
// Handles: base, begin, commit, checkpoint, checkpoints, restore, q / quit / exit
//
// `base` is the one piece of session state that outlives the session: `base <path>`
// remembers it in the Semel home, where the next launch starts from it (`RememberedBase`).
//
// `begin` and `commit` are for a script that pushes in several steps. Every push already
// opens a batch around its own files, so the engine settles once per command; a script
// whose tree arrives over several commands would settle after each, building and
// reporting on a tree that is not all there. A batch opened by hand spans the commands
// and the engine sees one push. There is no `discard`: a push is in the input file system
// the moment it lands, so nothing short of removing the files undoes it, and a verb that
// promised otherwise would quietly commit.
//
// The outermost `commit` is also where a batch is checked against the locks in `input:`
// (B-146): a batch that moved a locked folder without its lock is taken back whole, and the
// commit fails saying which folder, which lock and which paths. `checkpoint`, `checkpoints`
// and `restore` are the same machinery used on purpose: a checkpoint names the tree
// `input:` holds, and a restore is one batch back to it.

import Foundation
import SemelNodeKit

final class SessionPlugin: CommandPlugin {

    let verbs: Set<String> = ["base", "begin", "commit", "checkpoint", "checkpoints", "restore", "q", "quit", "exit"]

    func handle(verb: String, tokens: [String], context: any CommandContext) throws {
        switch verb {
        case "base":
            handleBase(externalPath: tokens.first, context: context)

        case "begin":
            try handleBegin(context: context)

        case "commit":
            try handleCommit(context: context)

        case "checkpoint":
            guard tokens.count <= 1 else {
                throw CommandParserError.missingArgument(command: "checkpoint", expected: "[name]")
            }
            try handleCheckpoint(name: tokens.first, context: context)

        case "checkpoints":
            try handleCheckpoints(context: context)

        case "restore":
            guard tokens.count == 1, let name = tokens.first else {
                throw CommandParserError.missingArgument(command: "restore", expected: "name")
            }
            try handleRestore(name: name, context: context)

        case "q", "quit", "exit":
            // A watcher is a child of the prompt that started it (B-126).
            context.stopRunningWatcher()
            throw CommandInterpreterError.quit

        default:
            break
        }
    }

    // MARK: - begin, commit

    /// Opens a batch. Nested begins are one batch, on both sides: the engine and the
    /// server's session count depth, and only the outermost `commit` releases it.
    private func handleBegin(context: any CommandContext) throws {
        _ = try context.request(.beginBatch)
        context.openBatchDepth += 1
    }

    /// Ends the batch, and when that was the outermost one, waits for what it released:
    /// the engine schedules on the end, so the commit is the natural place to see it
    /// settle, and a `wait` typed with the batch still open would never return.
    ///
    /// A batch the lock barrier refused is gone on the server, taken back whole, and so it
    /// is gone here: the depth goes to zero and the refusal is the command's error.
    private func handleCommit(context: any CommandContext) throws {
        guard context.openBatchDepth > 0 else {
            context.outputError("commit: no batch is open")
            return
        }
        do {
            _ = try context.request(.endBatch)
        } catch let failure as ServerError {
            if case .batchRejected = failure.response {
                context.openBatchDepth = 0
            }
            throw failure
        }
        context.openBatchDepth -= 1
        guard context.openBatchDepth == 0 else {
            return
        }
        try EnginePlugin.waitForSettle(context: context)
    }

    // MARK: - checkpoint, checkpoints, restore

    /// Names the tree `input:` holds: one hash, and every object below it is in the store
    /// already, so recording one copies nothing. A value, not a moment — two checkpoints of
    /// one tree print one hash.
    private func handleCheckpoint(name: String?, context: any CommandContext) throws {
        guard case .checkpoint(let recorded, let root) = try context.request(.checkpoint(name: name)).0 else {
            return
        }
        context.outputMessage("Checkpoint \(recorded): \(DependencyLock.contentScheme)\(root)")
    }

    /// Every checkpoint, by name, with the root it names.
    private func handleCheckpoints(context: any CommandContext) throws {
        guard case .checkpoints(let entries) = try context.request(.checkpoints).0 else {
            return
        }
        guard !entries.isEmpty else {
            context.outputMessage("No checkpoints. `checkpoint [<name>]` records one.")
            return
        }
        let width = entries.map(\.name.count).max() ?? 0
        for entry in entries {
            let padding = String(repeating: " ", count: width - entry.name.count + 2)
            context.outputMessage("\(entry.name)\(padding)\(DependencyLock.contentScheme)\(entry.contentRoot)")
        }
    }

    /// Brings `input:` back to the tree a checkpoint names, in one batch, and — when no
    /// batch was open around it — waits for the one settle it causes, as `commit` waits.
    /// Every node downstream reads what it read when the tree was last this one, so the
    /// settle is answered from the cache.
    private func handleRestore(name: String, context: any CommandContext) throws {
        guard case .restored(let restored, let root, let changed) = try context.request(.restore(name: name)).0 else {
            return
        }
        let paths = changed == 1 ? "1 path" : "\(changed) paths"
        context.outputMessage("Restored \(FileSystemName.input) to checkpoint \(restored) "
                              + "(\(DependencyLock.contentScheme)\(root)): \(paths) changed")
        guard context.openBatchDepth == 0, changed > 0 else {
            return
        }
        try EnginePlugin.waitForSettle(context: context)
    }

    // MARK: - base

    /// Sets the session's base and remembers it for the next launch (B-136): a person sets
    /// the base because the tree is somewhere other than where the terminal opens, and the
    /// next launch's terminal opens there too.
    private func handleBase(externalPath: String?, context: any CommandContext) {
        guard let externalPath else {
            context.outputMessage(context.baseDirectory)
            return
        }
        guard externalPath != Self.forgetFlag else {
            forgetBase(context: context)
            return
        }

        let expandedPath = ExternalPathSanitizer.expandPartialPath(externalPath)
        // A directory, not merely something there: a file remembered as the base would be
        // passed over as gone at every launch.
        guard LaunchBase.isFolder(expandedPath) else {
            context.outputError("Path is not an existing directory: \(externalPath)")
            return
        }
        context.baseDirectory = expandedPath
        do {
            try RememberedBase(directory: expandedPath).write(to: RememberedBase.file)
        } catch {
            // The session has its base either way; only the next launch is affected.
            context.outputError("Base directory set to \(expandedPath), but not remembered: \(error)")
            return
        }
        context.outputMessage("Base directory set to \(expandedPath) and remembered")
    }

    static let forgetFlag = "--forget"

    /// Removes the remembered base. The session keeps the base it has: forgetting is about
    /// where the next launch starts, and a session whose base moved under it would push
    /// from somewhere it was not told.
    private func forgetBase(context: any CommandContext) {
        let forgotten: Bool
        do {
            forgotten = try RememberedBase.forget(at: RememberedBase.file)
        } catch {
            context.outputError("base \(Self.forgetFlag): \(error)")
            return
        }
        guard forgotten else {
            context.outputMessage("No base directory was remembered; this session's is \(context.baseDirectory)")
            return
        }
        context.outputMessage("Base directory no longer remembered; this session's is still \(context.baseDirectory)")
    }
}
