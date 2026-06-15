//
//  DebugPrint.swift
//  build_system
//

import Foundation
import GRDB
import DatabaseModels

extension String {
    fileprivate func replaceNonprintableChars() -> String {
        map { char -> String in
            if char.isASCII {
                if char.isNewline {
                    return "\\n"
                } else {
                    return String(char)
                }
            } else {
                return "�"
            }
        }.joined()
    }

    fileprivate func truncate(maxLength: Int = 80) -> String {
        if count > maxLength {
            return String(prefix(maxLength)) + "…"
        } else {
            return self
        }
    }
}

extension BuildEngine {
    private static func formatPossibleString(bytes: [UInt8]?) -> String {
        guard let bytes else {
            return "nil"
        }
        if let string = String(bytes: bytes, encoding: .utf8) {
            return "\"\(string.replaceNonprintableChars().truncate())\""
        } else {
            return bytes.asHex().truncate()
        }
    }

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
        let allNodes       = try database.selectAllNodes()
        let allWires       = try database.selectAllWires()
        let allDataObjects = try database.selectAllDataObjects()

        let nodeByID: [ObjectID: Node] = Dictionary(
            uniqueKeysWithValues: allNodes.compactMap { node in node.id.map { ($0, node) } })
        let wiresByFromNodeID: [ObjectID: [Wire]] = Dictionary(grouping: allWires,  by: { $0.fromNodeID })
        let wiresByToNodeID:   [ObjectID: [Wire]] = Dictionary(grouping: allWires,  by: { $0.toNodeID   })

        func descriptorFor(_ node: Node) -> NodeFunctionDescriptor? {
            (try? node.nodeFunction())?.descriptor
        }

        func formatOutputValue(_ outputValue: DatabaseModels.OutputPort) -> String {
            switch outputValue.valueKind {
            case .value:
                let hash = outputValue.dataObjectHash ?? "nil"
                let preview = (try? Self.formatPossibleString(bytes: outputValue.dataObjectHash?.resolve())) ?? ""
                return "✔ \(hash.truncate()) = \(preview)"
            case .pending:
                return "⏳ pending"
            case .error:
                let message = (try? outputValue.dataObjectHash?.resolveAsString()) ?? "<no message>"
                return "❌ \(message)"
            }
        }

        // ─────────────────────────────────────────────
        // Section 1: Nodes
        // ─────────────────────────────────────────────
        print("BUILD GRAPH STATE")
        print("=================")
        print()

        for rawNode in allNodes {
            guard let nodeID = rawNode.id else { continue }

            let name        = rawNode.name ?? "?"
            let kindName    = (try? PolyFactory.type(kind: rawNode.kind)).map { String(describing: $0) } ?? "kind:\(rawNode.kind)"
            let scheduled   = rawNode.scheduled ? "⏱ scheduled" : "idle"
            let searchKey   = rawNode.searchKey ?? "nil"

            print("⬢ \(name)  [\(kindName)]  #\(nodeID)  \(scheduled)")
            print("  searchKey: \(searchKey)")

            if let parentNodeID = rawNode.parentNodeID {
                let parentName = nodeByID[parentNodeID]?.name ?? "?"
                print("  parent: \(parentName) #\(parentNodeID)")
            }

            let descriptor   = descriptorFor(rawNode)
            let inputPorts   = (descriptor?.staticInputPorts ?? []) + (descriptor?.dynamicInputPorts ?? [])
            let outputPorts  = descriptor?.outputPorts ?? []
            let incomingWires = wiresByToNodeID[nodeID]   ?? []
            let outgoingWires = wiresByFromNodeID[nodeID] ?? []
            let outputValues  = (try? database.selectAllOutputPorts(nodeID: nodeID)) ?? []

            if !inputPorts.isEmpty {
                print("  inputs:")
                for inputPort in inputPorts {
                    let dynamic = descriptor?.dynamicInputPorts.contains(inputPort) == true ? " (dynamic)" : ""
                    let connectedWires = incomingWires.filter { $0.toSymbolID == inputPort.asSymbolID() }
                    if connectedWires.isEmpty {
                        print("    · \(inputPort)\(dynamic)  — disconnected")
                    } else {
                        for wire in connectedWires {
                            let sourceNodeName = nodeByID[wire.fromNodeID]?.name ?? "?"
                            let fromSymbolName = (try? database.selectSymbol(symbolID: wire.fromSymbolID))?.name ?? "?"
                            print("    · \(inputPort)\(dynamic)  ◀── \(sourceNodeName):\(fromSymbolName)")
                        }
                    }
                }
            }

            if !outputPorts.isEmpty {
                print("  outputs:")
                for outputPort in outputPorts {
                    let outputSymbolID  = outputPort.asSymbolID()
                    let connectedWires  = outgoingWires.filter { $0.fromSymbolID == outputSymbolID }
                    let outputValue     = outputValues.first(where: { $0.nameSymbolID == outputSymbolID })
                    let valueDesc       = outputValue.map { formatOutputValue($0) } ?? "—"
                    if connectedWires.isEmpty {
                        print("    · \(outputPort)  [\(valueDesc)]  — no wires")
                    } else {
                        for wire in connectedWires {
                            let destinationNodeName = nodeByID[wire.toNodeID]?.name ?? "?"
                            let toSymbolName        = (try? database.selectSymbol(symbolID: wire.toSymbolID))?.name ?? "?"
                            print("    · \(outputPort)  [\(valueDesc)]  ──▶ \(destinationNodeName):\(toSymbolName)")
                        }
                    }
                }
            }

            print()
        }

        // ─────────────────────────────────────────────
        // Section 2: Wire list
        // ─────────────────────────────────────────────
        if !allWires.isEmpty {
            print("WIRES (\(allWires.count))")
            print("=================")
            for wire in allWires {
                let fromNodeName   = nodeByID[wire.fromNodeID]?.name ?? "?"
                let toNodeName     = nodeByID[wire.toNodeID]?.name   ?? "?"
                let fromSymbolName = (try? database.selectSymbol(symbolID: wire.fromSymbolID))?.name ?? "?"
                let toSymbolName   = (try? database.selectSymbol(symbolID: wire.toSymbolID))?.name   ?? "?"
                print("  · \(fromNodeName):\(fromSymbolName)  ──▶  \(toNodeName):\(toSymbolName)")
            }
            print()
        }

        // ─────────────────────────────────────────────
        // Section 3: Data objects
        // ─────────────────────────────────────────────
        if !allDataObjects.isEmpty {
            print("DATA OBJECTS (\(allDataObjects.count))")
            print("=================")
            for dataObject in allDataObjects {
                print("  · 🗄 \(dataObject.content.count) byte(s): \(Self.formatPossibleString(bytes: dataObject.content))")
            }
            print()
        }

        (try Node.rootNode.nodeFunction() as! RootNode).debugPrintTree()
    }
}
