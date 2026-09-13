// EnginePlugin.swift
// semel
//
// Handles: d / debug, n / nudge, e / errors, reset, t / tools

import Foundation
import SemelProtocol

final class EnginePlugin: CommandPlugin {

    let verbs: Set<String> = ["d", "debug", "n", "nudge", "e", "errors", "reset", "t", "tools"]

    func handle(verb: String, tokens: [String], context: any CommandContext) throws {
        switch verb {
        case "d", "debug":  try handleDebug(context: context)
        case "n", "nudge":  _ = try context.request(.nudge)
        case "e", "errors": try handleErrors(context: context)
        case "reset":       try handleReset(context: context)
        case "t", "tools":  try handleTools(context: context)
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

        for record in records {
            ErrorRecordRenderer.lines(for: record).forEach { context.outputMessage($0) }
        }
    }
}
