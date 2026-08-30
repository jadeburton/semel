// EnginePlugin.swift
// build_system
//
// Handles: d / debug, n / nudge, e / errors, reset

import SemelCore
import Foundation

final class EnginePlugin: CommandPlugin {

    let verbs: Set<String> = ["d", "debug", "n", "nudge", "e", "errors", "reset"]

    func handle(verb: String, tokens: [String], context: any CommandContext) throws {
        switch verb {
        case "d", "debug":  try context.buildEngine.printAll()
        case "n", "nudge":  try context.buildEngine.nudge()
        case "e", "errors": try handleErrors(context: context)
        case "reset":       try handleReset(context: context)
        default:            break
        }
    }

    // MARK: - reset

    private func handleReset(context: any CommandContext) throws {
        try context.buildEngine.reset()
        context.outputMessage("Rebuild started.")
    }

    // MARK: - errors

    private func handleErrors(context: any CommandContext) throws {
        let errorPorts = try context.database.outputPort.selectAllErrors()

        if errorPorts.isEmpty {
            context.outputMessage("No errors.")
            return
        }

        let byNode     = Dictionary(grouping: errorPorts, by: \.nodeID)
        let errorCount = errorPorts.count
        let nodeCount  = byNode.count

        let sortedNodeIDs = byNode.keys.sorted { a, b in
            let nameA = (try? context.database.node.select(nodeID: a))?.name ?? ""
            let nameB = (try? context.database.node.select(nodeID: b))?.name ?? ""
            return nameA < nameB
        }

        context.outputMessage("\(errorCount) error\(errorCount == 1 ? "" : "s") across " +
                              "\(nodeCount) node\(nodeCount == 1 ? "" : "s"):\n")

        for nodeID in sortedNodeIDs {
            let ports = byNode[nodeID] ?? []

            // Every distinct message this node is carrying. Asked for explicitly, so unlike
            // the engine's own reporting there is nothing to suppress — the whole point of
            // running `errors` is to see what is there, including what was reported before.
            let messages = Set(ports.compactMap(ErrorReport.reportableMessage))

            ErrorReport.lines(forNodeID: nodeID,
                              ports: ports,
                              messages: messages,
                              database: context.database).forEach { context.outputMessage($0) }
        }
    }
}
