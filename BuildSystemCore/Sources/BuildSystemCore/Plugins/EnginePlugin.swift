// EnginePlugin.swift
// build_system
//
// Handles: debug, nudge, errors

import Foundation

final class EnginePlugin: CommandPlugin {

    func handle(_ command: UserCommand, context: any CommandContext) throws -> Bool {
        switch command {
        case .debug:  try context.buildEngine.printAll()
        case .nudge:  try context.buildEngine.nudge()
        case .errors: try handleErrors(context: context)
        default: return false
        }
        return true
    }

    // MARK: - errors

    private func handleErrors(context: any CommandContext) throws {
        let errorPorts = try context.database.outputPort.selectAllErrors()

        if errorPorts.isEmpty { context.outputMessage("No errors."); return }

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
            let node     = try? context.database.node.select(nodeID: nodeID)
            let nodeName = node?.name ?? "Node \(nodeID)"

            let kindLabel: String
            if let node, let nf = try? node.nodeFunction() {
                let typeName = String(describing: type(of: nf))
                kindLabel = typeName == nodeName ? nodeName : "\(nodeName)  [\(typeName)]"
            } else {
                kindLabel = nodeName
            }

            context.outputMessage("❌ \(kindLabel)")

            for port in byNode[nodeID]! {
                let portName     = port.nameSymbolID.resolveSymbol()
                let errorMessage = (try? port.dataObjectHash?.resolveAsString()) ?? ""

                if errorMessage.isEmpty {
                    context.outputMessage("   · \(portName): (no details)")
                } else {
                    let lines = errorMessage
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .components(separatedBy: "\n")
                        .map    { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }

                    if lines.count == 1 {
                        context.outputMessage("   · \(portName): \(lines[0])")
                    } else {
                        context.outputMessage("   · \(portName):")
                        lines.forEach { context.outputMessage("     \($0)") }
                    }
                }
            }
            context.outputMessage("")
        }
    }
}
