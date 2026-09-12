//
//  DebugPrint.swift
//  semel
//

import Foundation
import GRDB
import SemelDatabaseModels
import SemelNodeKit

// MARK: - String helpers

extension String {
    fileprivate func replacingNonprintableCharacters() -> String {
        map { char -> String in
            char.isASCII ? (char.isNewline ? "\\n" : String(char)) : "�"
        }.joined()
    }

    func truncated(to maxLength: Int = 80) -> String {
        count > maxLength ? String(prefix(maxLength)) + "…" : self
    }
}

// MARK: - printAll

extension BuildEngine {

    // MARK: Private helpers

    /// Format raw bytes as a quoted UTF-8 string, or hex if not valid UTF-8.
    private func formatBytes(_ bytes: [UInt8]?) -> String {
        guard let bytesUnlimited = bytes else {
            return "nil"
        }

        let bytes = bytesUnlimited.prefix(128)

        if let string = String(bytes: bytes, encoding: .utf8) {
            return "\"\(string.replacingNonprintableCharacters().truncated())\""
        }
        return bytes.asHex().truncated()
    }

    /// Resolve a DataObjectHash to its content and format it.
    private func formatHash(_ hash: DataObjectHash?) -> String {
        formatBytes(try? hash?.resolve())
    }

    /// Resolve a symbol ID to its name, falling back to "?".
    private func symbolName(symbolID: ObjectID, database: DatabaseLayer) -> String {
        (try? database.symbol.select(symbolID: symbolID))?.name ?? "<invalid symbolID>"
    }

    /// Format a wire as "fromNode:fromPort ──▶ toNode:toPort".
    private func formatWire(_ wire: Wire, nodeByID: [ObjectID: NodeRecord], database: DatabaseLayer) -> String {
        let fromNode = nodeByID[wire.fromNodeID]?.name ?? "?"
        let toNode   = nodeByID[wire.toNodeID]?.name   ?? "?"
        let fromPort = symbolName(symbolID: wire.fromSymbolID, database: database)
        let toPort   = symbolName(symbolID: wire.toSymbolID,   database: database)
        return "\(fromNode):\(fromPort)  ──▶  \(toNode):\(toPort)"
    }

    /// Format an output port value with an emoji status prefix.
    func formatOutputPort(_ outputPort: SemelDatabaseModels.OutputPort) -> String {
        switch outputPort.valueKind {
        case .value:
            let hash    = outputPort.dataObjectHash ?? "nil"
            let preview = formatHash(outputPort.dataObjectHash)
            return "[ \(hash.truncated(to: 12))  \(preview.truncated(to: 20)) ]"
        case .pending:
            return "[ 🟡 pending ]"
        case .error:
            let message = (try? outputPort.dataObjectHash?.resolveAsString()) ?? "<no message>"
            return "[ ❌ \(message) ]"
        }
    }

    /// Print a titled section header.
    private func printSectionHeader(_ title: String) {
        print(title)
        print(String(repeating: "─", count: title.count))
    }

    // MARK: nudge

    public func nudge() throws {
        _ = try database.cacheEntry.deleteAll()
        // Reset all Node outputs to pending so downstream nodes block on
        // stale values and wait for fresh upstream results (correct ordering).
        for nodeRecord in try database.node.selectAll() {
            guard let node = try? nodeRecord.makeNode(),
                  type(of: node).descriptor.hasInputs else { continue }
            try nodeRecord.writePendingToAllOutputsOfNode()
        }
        for nodeRecord in try database.node.selectAll() {
            try nodeRecord.setScheduled(true)
        }
    }

    // MARK: printAll

    public func printAll() throws {
        let allNodes = try database.node.selectAll()
        let allWires = try database.wire.selectAll()

        // Indexes built once and reused throughout
        let nodeByID: [ObjectID: NodeRecord] = Dictionary(
            uniqueKeysWithValues: allNodes.compactMap { node in node.id.map { ($0, node) } })
        let wiresByToNodeID:   [ObjectID: [Wire]] = Dictionary(grouping: allWires, by: \.toNodeID)
        let wiresByFromNodeID: [ObjectID: [Wire]] = Dictionary(grouping: allWires, by: \.fromNodeID)

        // MARK: Section 1 — Nodes

        printSectionHeader("BUILD GRAPH STATE (\(allNodes.count) nodes)")
        print()

        for nodeRecord in allNodes {
            guard let nodeID = nodeRecord.id else { continue }
            
            let scheduled = nodeRecord.scheduled ? "⏱ scheduled" : ""
            print("⬢ \(type(of: try nodeRecord.makeNode())) #\(nodeID)  \(scheduled)")

            if let name = nodeRecord.name {
                print("  name: '\(name)'")
            }

            if let searchKey = nodeRecord.searchKey {
                let graphShapeNode = try GraphShapeNode.parse(searchKey)
                print("  searchKey:\n\(graphShapeNode.asString(pretty: true, omitOutputPort: true))\n")
            } else {
                print("  searchKey: nil")
            }

            if let parentNodeID = nodeRecord.parentNodeID {
                print("  parent: \(nodeByID[parentNodeID]?.name ?? "?") #\(parentNodeID)")
            }

            let descriptor    = (try? nodeRecord.makeNode())?.descriptor
            let inputPorts    = (descriptor?.staticInputPorts  ?? []) + (descriptor?.dynamicInputPorts ?? [])
            let outputPorts   =  descriptor?.outputPorts ?? []
            let incomingWires = wiresByToNodeID[nodeID]   ?? []
            let outgoingWires = wiresByFromNodeID[nodeID] ?? []
            let outputValues  = (try? database.outputPort.selectAll(nodeID: nodeID)) ?? []

            if !inputPorts.isEmpty {
                print("  inputs:")
                for inputPort in inputPorts {
                    let dynamic = descriptor?.dynamicInputPorts.contains(inputPort) == true ? " (dynamic)" : ""
                    let inputSymbolID = inputPort.asSymbolID()
                    let wires   = incomingWires.filter { $0.toSymbolID == inputSymbolID }
                    if wires.isEmpty {
                        print("    · \(inputPort)\(dynamic)  — no wires")
                    } else {
                        for wire in wires {
                            let fromNode = nodeByID[wire.fromNodeID]?.name ?? "?"
                            let fromPort = symbolName(symbolID: wire.fromSymbolID, database: database)
                            let outputValue = (try? database.outputPort.select(nodeID: wire.fromNodeID, nameSymbolID: wire.fromSymbolID)).map { formatOutputPort($0) } ?? "—"
                            print("    · \(inputPort)\(dynamic)  ◀──(\(wire.name.resolveSymbol()))── #\(wire.fromNodeID) \(fromNode):\(fromPort)   \(outputValue)")
                        }
                    }
                }
            }

            if !outputPorts.isEmpty {
                print("  outputs:")
                for outputPort in outputPorts {
                    let symbolID   = outputPort.asSymbolID()
                    let wires      = outgoingWires.filter { $0.fromSymbolID == symbolID }
                    let portValue  = outputValues.first { $0.nameSymbolID == symbolID }
                    let valueDesc  = portValue.map { formatOutputPort($0) } ?? "—"
                    if wires.isEmpty {
                        print("    · \(outputPort)  \(valueDesc)  — no wires")
                    } else {
                        for wire in wires {
                            let toNode = nodeByID[wire.toNodeID]?.name ?? "?"
                            let toPort = symbolName(symbolID: wire.toSymbolID, database: database)
                            print("    · \(outputPort)  \(valueDesc)  ────▶ #\(wire.toNodeID) \(toNode):\(toPort)")
                        }
                    }
                }
            }

            print()
        }

        // Debug output must never be the thing that takes the process down.
        let outputPortCount = (try? database.outputPort.selectAllCount()).map(String.init) ?? "unavailable"
        print("OutputPort count: \(outputPortCount)\n")

        debugPrintTree()
    }

    func debugPrintTree() {
        do {
            print("- build tree")
            try projectFinder.printDependencyTree(indentLevel: 1)
        } catch {
            print("- build tree (error: \(error))")
        }
    }
}

extension NodeRecord {

    fileprivate func printDependencyTree(indentLevel: Int) {
        let indent = String(repeating: "  ", count: indentLevel)

        // Debug output must never be the thing that takes the process down: an
        // unregistered kind here means the tree prints "kind 27?" rather than crashing.
        let kindName = (try? makeNode()).map { String(describing: type(of: $0)) }
                    ?? "kind \(kind)?"

        let nodeName = name ?? ""

        guard let nodeID = id else {
            print("\(indent)- \(kindName)(\(nodeName)) [unsaved]")
            return
        }

        print("\(indent)- \(kindName)(\(nodeName)) \(nodeID)")

        do {
            let incomingWires = try database.wire.select(goingToNodeID: nodeID)

            var visitedDependencyNodeIDs = Set<ObjectID>()
            var dependencyNodes = [NodeRecord]()

            for wire in incomingWires {
                guard !visitedDependencyNodeIDs.contains(wire.fromNodeID) else { continue }
                visitedDependencyNodeIDs.insert(wire.fromNodeID)

                if let nodeRecord = try? database.node.select(nodeID: wire.fromNodeID) {
                    dependencyNodes.append(nodeRecord)
                }
            }

            for dependencyNode in dependencyNodes {
                dependencyNode.printDependencyTree(indentLevel: indentLevel + 1)
            }
        } catch {
            print("\(indent)  (error loading dependencies: \(error))")
        }
    }
}
