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
        case "t", "tools":  try handleTools(tokens: tokens, context: context)
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
        _ = try context.request(.wait)
        context.outputMessage("Settled.")
    }

    // MARK: - tools

    /// With no argument, every namespace. With a prefix, only the namespaces whose name
    /// starts with it — `tools clang` gives the three `clang.*` blocks a newcomer copying
    /// a `clang.cfg` needs, instead of all eight. Filtered on the client: the records
    /// already carry the namespace, so the server has nothing to add.
    private func handleTools(tokens: [String], context: any CommandContext) throws {
        guard case .tools(let namespaces) = try context.request(.tools).0 else {
            return
        }
        guard !namespaces.isEmpty else {
            context.outputMessage("No toolchains are registered.")
            return
        }

        guard let prefix = tokens.first else {
            context.outputMessage(ToolNamespaceRenderer.text(for: namespaces))
            return
        }

        let matching = namespaces.filter { $0.namespace.hasPrefix(prefix) }
        guard !matching.isEmpty else {
            let known = namespaces.map(\.namespace).sorted().joined(separator: ", ")
            context.outputMessage("No namespace starts with '\(prefix)'. Namespaces: \(known).")
            return
        }

        context.outputMessage(ToolNamespaceRenderer.text(for: matching))
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

        // Through outputError: a scripted run's exit status rests on the count of errors
        // reported, and a build that failed is what that status is for.
        context.outputError("\(errorCount) error\(errorCount == 1 ? "" : "s") across " +
                            "\(nodeCount) node\(nodeCount == 1 ? "" : "s"):\n")

        for record in records {
            ErrorRecordRenderer.lines(for: record).forEach { context.outputMessage($0) }
        }
    }
}
