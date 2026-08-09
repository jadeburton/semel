// EnginePlugin.swift
// build_system
//
// Handles: d / debug, n / nudge, e / errors

import BuildSystemCore
import Foundation

final class EnginePlugin: CommandPlugin {

    let verbs: Set<String> = ["d", "debug", "n", "nudge", "e", "errors"]

    func handle(verb: String, tokens: [String], context: any CommandContext) throws {
        switch verb {
        case "d", "debug":  try context.buildEngine.printAll()
        case "n", "nudge":  try context.buildEngine.nudge()
        case "e", "errors": try handleErrors(context: context)
        default:            break
        }
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
            let node = try? context.database.node.select(nodeID: nodeID)

            // Build a user-friendly label: TypeName + meaningful identifier.
            // Internal node IDs (surrogate ints) are not shown to the user.
            let kindLabel: String
            if let node, let nf = try? node.nodeAsAny() {
                let typeName = String(describing: type(of: nf))
                if let path = node.properties["path"] {
                    // Nodes with a static path property (Folder, StaticFile, …)
                    kindLabel = "\(typeName)  '\(path)'"
                } else if let wires = try? context.database.wire.select(
                                goingToNodeID: nodeID,
                                toSymbolID: "projectFile".asSymbolID()),
                          let wireName = wires.first?.name {
                    // ProjectBuilder: the projectFile wire name is the .fmla path
                    kindLabel = "\(typeName)  '\(wireName.resolveSymbol())'"
                } else {
                    kindLabel = typeName
                }
            } else {
                kindLabel = "Node \(nodeID)"
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
