//
//  DebugPrint.swift
//  build_system
//

import Foundation
import GRDB
import DatabaseModels

extension BuildEngine {
    static func nudge() throws {
        let database = DatabaseLayer.shared
        let allNodes = try database.selectAllNodes()
        for node in allNodes {
            if try node.hasOneOrMoreErrorOutputs() {
                var node = node
                try node.setScheduledAndSave(true)
            }
        }
    }

    static func printAll() throws {
        try DatabaseLayer.shared.recomputeAllSearchKeys()
        var pf = try Node.projectFinder
        try pf.setScheduledAndSave(true)

        let database = DatabaseLayer.shared
        let allNodes        = try database.selectAllNodes()
        let allWires        = try database.selectAllWires()
        //let allOutputValues = try database.selectAllPorts(limit: 10_000_000)
        let allDataObjects  = try database.selectAllDataObjects()

        // Index helpers
        let nodeByID: [ObjectID: Node] = Dictionary(
            uniqueKeysWithValues: allNodes.compactMap { node in node.id.map { ($0, node) } })
//        let outputValuesByNodeID: [ObjectID: [DatabaseModels.Port]] =
//            Dictionary(grouping: allOutputValues, by: { $0.nodeID })
        let wiresByFromNodeID: [ObjectID: [Wire]] = Dictionary(grouping: allWires, by: { $0.fromNodeID })
        let wiresByToNodeID:   [ObjectID: [Wire]] = Dictionary(grouping: allWires, by: { $0.toNodeID })

        func descriptorFor(_ node: Node) -> NodeFunctionDescriptor? {
            guard let nodeFunction = try? node.nodeFunction() else { return nil }
            return nodeFunction.descriptor
        }

        func labelForNode(_ rawNode: Node) -> String {
            let name = rawNode.name ?? "?"
            let kindName = (try? PolyFactory.type(kind: rawNode.kind))
                .map { String(describing: $0) } ?? "kind:\(rawNode.kind)"
            return "\(name) [\(kindName)] #\(rawNode.id ?? -1) scheduled: \(rawNode.scheduled) searchKey: '\(rawNode.searchKey ?? "nil")'"
        }

        func formatOutputValue(_ outputValue: DatabaseModels.OutputPort) -> String {
            switch outputValue.valueKind {
            case .value:
                let hash = outputValue.dataObjectHash ?? "nil"
                let shortHash = hash.count > 12 ? String(hash.prefix(12)) + "…" : hash
                return "✔ '\(shortHash)'"
            case .pending:
                return "⏳ pending"
            case .error:
                let hash = outputValue.dataObjectHash ?? "nil"
                let shortHash = hash.count > 12 ? String(hash.prefix(12)) + "…" : hash
                return "❌ error '\((try? outputValue.dataObjectHash?.resolveAsString()) ?? "<no message>")' hash '\(shortHash)'"
            }
        }

        // ─────────────────────────────────────────────
        // Section 1: Node boxes
        // ─────────────────────────────────────────────
        print("╔══════════════════════════════════════════════╗")
        print("║              BUILD GRAPH STATE               ║")
        print("╚══════════════════════════════════════════════╝")
        print()

        for rawNode in allNodes {
            guard let nodeID = rawNode.id else { continue }
            let label            = labelForNode(rawNode)
            let descriptor       = descriptorFor(rawNode)
            let inputPorts       = (descriptor?.staticInputPorts ?? []) + (descriptor?.dynamicInputPorts ?? [])
            let outputPorts      = descriptor?.outputPorts ?? []
            let incomingWires    = wiresByToNodeID[nodeID]   ?? []
            let outgoingWires    = wiresByFromNodeID[nodeID] ?? []
            let outputValues     = try database.selectAllOutputPorts(nodeID: nodeID)

            var contentLines = [String]()

            if let parentNodeID = rawNode.parentNodeID {
                let parentName = nodeByID[parentNodeID]?.name ?? "?"
                contentLines.append("  parent: \(parentName) #\(parentNodeID)")
            }

            if !inputPorts.isEmpty {
                contentLines.append("  ┌─ inputs ─────────────────────")
                for inputPort in inputPorts {
                    let dynamicPort = descriptor?.dynamicInputPorts.contains(inputPort) == true ? "(dynamic)" : ""
                    let connectedWires = incomingWires.filter { $0.toSymbolID == inputPort.asSymbolID() }
                    if connectedWires.isEmpty {
                        contentLines.append("  │ ▸ \"\(inputPort)\" \(dynamicPort)  (disconnected)")
                    } else {
                        for wire in connectedWires {
                            let sourceNodeName = nodeByID[wire.fromNodeID]?.name ?? "?"
                            let fromSymbolName = (try database.selectSymbol(symbolID: wire.fromSymbolID))?.name ?? "?"
                            contentLines.append("  │ ▸ \"\(inputPort)\" \(dynamicPort) ◀── #\(wire.fromNodeID) \"\(sourceNodeName)\" :\(fromSymbolName)")
                        }
                    }
                }
                contentLines.append("  └─────────────────────────────")
            }

            if !outputPorts.isEmpty {
                contentLines.append("  ┌─ outputs ────────────────────")
                for outputPort in outputPorts {
                    let outputSymbolID = outputPort.asSymbolID()
                    let connectedWires = outgoingWires.filter { $0.fromSymbolID == outputSymbolID }
                    let outputValue = outputValues.first(where: { $0.nameSymbolID == outputSymbolID }) // ?
                    let valueDescription = outputValue.map { formatOutputValue($0) } ?? "<missing>"
                    if connectedWires.isEmpty {
                        contentLines.append("  │ ▹ \"\(outputPort)\"  [\(valueDescription)]  (no wires)")
                    } else {
                        for wire in connectedWires {
                            let destinationNodeName = nodeByID[wire.toNodeID]?.name ?? "?"
                            let toSymbolName        = (try database.selectSymbol(symbolID: wire.toSymbolID))?.name ?? "?"
                            contentLines.append("  │ ▹ \"\(outputPort)\"  [\(valueDescription)]  ──▶ #\(wire.toNodeID) \"\(destinationNodeName)\" :\(toSymbolName)")
                        }
                    }
                }
                contentLines.append("  └─────────────────────────────")
            }

            let contentWidth = max(label.count, (contentLines.map { $0.count }.max() ?? 0)) + 4
            let boxWidth = max(contentWidth, 40)

            let topBorder    = "┌" + String(repeating: "─", count: boxWidth) + "┐"
            let bottomBorder = "└" + String(repeating: "─", count: boxWidth) + "┘"
            let separator    = "├" + String(repeating: "─", count: boxWidth) + "┤"

            func padLine(_ text: String) -> String {
                let padding = boxWidth - text.count
                return "│ " + text + String(repeating: " ", count: max(0, padding - 1)) + "│"
            }

            print(topBorder)
            print(padLine("⬢ " + label))
            if !contentLines.isEmpty {
                print(separator)
                for contentLine in contentLines { print(padLine(contentLine)) }
            }
            print(bottomBorder)
            print()
        }

        // ─────────────────────────────────────────────
        // Section 2: Wire list
        // ─────────────────────────────────────────────
        if !allWires.isEmpty {
            print("──────────────────────────────────────────────")
            print("  WIRES (\(allWires.count))")
            print("──────────────────────────────────────────────")
            for wire in allWires {
                let fromNodeName   = nodeByID[wire.fromNodeID]?.name ?? "?"
                let toNodeName     = nodeByID[wire.toNodeID]?.name   ?? "?"
                let fromSymbolName = (try database.selectSymbol(symbolID: wire.fromSymbolID))?.name ?? "?"
                let toSymbolName   = (try database.selectSymbol(symbolID: wire.toSymbolID))?.name   ?? "?"
                print("  \"\(fromNodeName)\" :\(fromSymbolName)  ───▶  \"\(toNodeName)\" :\(toSymbolName)")
            }
            print("──────────────────────────────────────────────")
            print()
        }

        // ─────────────────────────────────────────────
        // Section 3: Data objects
        // ─────────────────────────────────────────────
        if !allDataObjects.isEmpty {
            print("──────────────────────────────────────────────")
            print("  DATA OBJECTS (\(allDataObjects.count))")
            print("──────────────────────────────────────────────")
            for dataObject in allDataObjects {
                let shortHash = dataObject.hash.count > 16 ? String(dataObject.hash.prefix(16)) + "…" : dataObject.hash
                print("│  🗄 \(shortHash)  \(dataObject.content.count) byte(s)")
            }
            print("──────────────────────────────────────────────")
            print()
        }

        // ─────────────────────────────────────────────
        // Section 4: Output values
        // ─────────────────────────────────────────────
        /*if !allOutputValues.isEmpty {
            print("──────────────────────────────────────────────")
            print("  OUTPUT VALUES (\(allOutputValues.count))")
            print("──────────────────────────────────────────────")
            for outputValue in allOutputValues {
                if let node = nodeByID[outputValue.nodeID] { // BUG: the node should always be found, but if not, we should handle it more gracefully than crashing
                    let nodeDecoded = try! PolyFactory.decode(encodedJSON: node.configuration!) as! NodeFunction
                    let matchingOutputPort = nodeDecoded.descriptor.outputs.first(where: { $0.index == outputValue.port })
                    let outputSymbol = matchingOutputPort?.name ?? ":\(outputValue.port)"
                    print("  \(type(of: nodeDecoded)) \"\(node.name ?? "?")\" #\(outputValue.nodeID) \(outputSymbol) (\(outputValue.port))  → \(formatOutputValue(outputValue))")
                } else {
                    print("  <deleted> nodeID = #\(outputValue.nodeID) port = \(outputValue.port)  → \(formatOutputValue(outputValue))")
                }
            }
            print("──────────────────────────────────────────────")
            print()
        }*/

        (try Node.rootNode.nodeFunction() as! RootNode).debugPrintTree()
    }
}

