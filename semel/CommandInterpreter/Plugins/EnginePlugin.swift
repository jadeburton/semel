// EnginePlugin.swift
// semel
//
// Handles: d / debug, n / nudge, e / errors, reset, t / tools, wait

import Foundation
import SemelProtocol

final class EnginePlugin: CommandPlugin {

    let verbs: Set<String> = ["d", "debug", "n", "nudge", "e", "errors", "reset", "t", "tools", "wait"]

    func handle(verb: String, tokens: [String], context: any CommandContext) throws {
        switch verb {
        case "d", "debug":  try handleDebug(context: context)
        case "n", "nudge":  _ = try context.request(.nudge)
        case "e", "errors": try handleErrors(context: context)
        case "reset":       try handleReset(context: context)
        case "t", "tools":  try handleTools(context: context)
        case "wait":        try handleWait(context: context)
        default:            break
        }
    }

    // MARK: - debug

    private func handleDebug(context: any CommandContext) throws {
        guard case .debug(let text) = try context.request(.debug).0 else {
            return
        }
        context.outputMessage(text)
    }

    // MARK: - wait

    /// Blocks until the build has settled: every scheduled node processed and nothing
    /// asked for another pass. What a script needs between `push` and `errors`, and what
    /// the prompt otherwise never says — a command returns while the build runs behind it.
    private func handleWait(context: any CommandContext) throws {
        // Before, not after: the settle-time event this unblocks (see the idle-time error
        // reporter) can fire and count *during* this request, ahead of `outputMessage`
        // below ever running.
        context.resetErrorRecordAccounting()
        _ = try context.request(.wait)
        context.outputMessage("Settled.")
    }

    // MARK: - tools

    private func handleTools(context: any CommandContext) throws {
        guard case .tools(let namespaces) = try context.request(.tools).0 else {
            return
        }
        if namespaces.isEmpty {
            context.outputMessage("No toolchains are registered.")
        } else {
            context.outputMessage(ToolNamespaceRenderer.text(for: namespaces))
        }
    }

    // MARK: - reset

    private func handleReset(context: any CommandContext) throws {
        _ = try context.request(.reset)
        context.outputMessage("Rebuild started.")
    }

    // MARK: - errors

    private func handleErrors(context: any CommandContext) throws {
        guard case .errors(let records) = try context.request(.errors).0 else {
            return
        }

        if records.isEmpty {
            context.outputMessage("No errors.")
            return
        }

        let errorCount = records.reduce(0) { $0 + $1.entries.reduce(0) { $0 + $1.ports.count } }
        let nodeCount  = records.count

        context.outputMessage("\(errorCount) error\(errorCount == 1 ? "" : "s") across " +
                              "\(nodeCount) node\(nodeCount == 1 ? "" : "s"):\n")

        // Through countErrorRecords, not outputError: a scripted run's exit status rests
        // on the count of settle reports, and the idle-time event this often follows may
        // have already counted this exact one.
        context.countErrorRecords(records)

        for record in records {
            ErrorRecordRenderer.lines(for: record).forEach { context.outputMessage($0) }
        }
    }
}
