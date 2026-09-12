// EnginePlugin.swift
// semel
//
// Handles: d / debug, n / nudge, e / errors, reset, t / tools

import SemelCore
import SemelNodeKit
import Foundation

final class EnginePlugin: CommandPlugin {

    let verbs: Set<String> = ["d", "debug", "n", "nudge", "e", "errors", "reset", "t", "tools"]

    func handle(verb: String, tokens: [String], context: any CommandContext) throws {
        switch verb {
        case "d", "debug":  try context.buildEngine.printAll()
        case "n", "nudge":  try context.buildEngine.nudge()
        case "e", "errors": try handleErrors(context: context)
        case "reset":       try handleReset(context: context)
        case "t", "tools":  handleTools(context: context)
        default:            break
        }
    }

    // MARK: - tools

    /// The installed tools, printed as the settings a `semel.config` needs — one block per
    /// namespace that names the tool, so choosing a toolchain version is a paste. A
    /// namespace whose tool is missing prints as a comment, so the whole output is safe to
    /// paste and still says what is absent.
    ///
    /// Both sources are dictionaries, so the order is imposed: namespaces alphabetically,
    /// and a tool installed in several versions by version.
    private func handleTools(context: any CommandContext) {
        let installed = ToolRunnerRegistry.instance.registeredDescriptors

        var blocks: [String] = []
        for entry in ToolNamespaceRegistry.all {
            let descriptors = installed
                .filter { $0.name == entry.toolName }
                .sorted { ($0.version, $0.platform, $0.architecture) < ($1.version, $1.platform, $1.architecture) }

            guard !descriptors.isEmpty else {
                blocks.append("// \(entry.namespace): no \(entry.toolName) is installed on this machine")
                continue
            }

            let machineSettings = entry.machineSettings()
            for descriptor in descriptors {
                var lines = [
                    "\(entry.namespace).toolDescriptor.name=\(descriptor.name)",
                    "\(entry.namespace).toolDescriptor.version=\(descriptor.version)",
                    "\(entry.namespace).toolDescriptor.platform=\(descriptor.platform)",
                    "\(entry.namespace).toolDescriptor.architecture=\(descriptor.architecture)",
                ]
                for key in machineSettings.keys.sorted() {
                    lines.append("\(entry.namespace).\(key)=\(machineSettings[key]!)")
                }
                blocks.append(lines.joined(separator: "\n"))
            }
        }

        if blocks.isEmpty {
            context.outputMessage("No toolchains are registered.")
        } else {
            context.outputMessage(blocks.joined(separator: "\n\n"))
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
