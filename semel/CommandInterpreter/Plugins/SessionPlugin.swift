// SessionPlugin.swift
// semel
//
// Handles: base, begin, commit, q / quit / exit
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

    private func handleBase(externalPath: String?, context: any CommandContext) {
        guard let externalPath else {
            context.outputMessage(context.baseDirectory)
            return
        }

        let expandedPath = ExternalPathSanitizer.expandPartialPath(externalPath)
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            context.outputError("Path refers to nonexistent directory: \(externalPath)")
            return
        }
        context.baseDirectory = expandedPath
        context.outputMessage("Base directory set to \(expandedPath)")
    }
}
