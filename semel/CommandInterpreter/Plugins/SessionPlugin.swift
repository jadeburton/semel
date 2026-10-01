// SessionPlugin.swift
// semel
//
// Handles: base, begin, commit, q / quit / exit
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

import Foundation
import SemelNodeKit

final class SessionPlugin: CommandPlugin {

    let verbs: Set<String> = ["base", "begin", "commit", "q", "quit", "exit"]

    func handle(verb: String, tokens: [String], context: any CommandContext) throws {
        switch verb {
        case "base":
            handleBase(externalPath: tokens.first, context: context)

        case "begin":
            try handleBegin(context: context)

        case "commit":
            try handleCommit(context: context)

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
    private func handleCommit(context: any CommandContext) throws {
        guard context.openBatchDepth > 0 else {
            context.outputError("commit: no batch is open")
            return
        }
        _ = try context.request(.endBatch)
        context.openBatchDepth -= 1
        guard context.openBatchDepth == 0 else {
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
