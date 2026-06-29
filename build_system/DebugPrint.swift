//
//  DebugPrint.swift
//  build_system
//

import Foundation
import GRDB
import DatabaseModels

// MARK: - String helpers

extension String {
    fileprivate func replacingNonprintableCharacters() -> String {
        map { char -> String in
            char.isASCII ? (char.isNewline ? "\\n" : String(char)) : "�"
        }.joined()
    }

    fileprivate func truncated(to maxLength: Int = 80) -> String {
        count > maxLength ? String(prefix(maxLength)) + "…" : self
    }
}

// MARK: - printAll

extension BuildEngine {

    // MARK: Private helpers

    /// Format raw bytes as a quoted UTF-8 string, or hex if not valid UTF-8.
    private func formatBytes(_ bytes: [UInt8]?) -> String {
        guard let bytes else { return "nil" }
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
        (try? database.selectSymbol(symbolID: symbolID))?.name ?? "<invalid symbolID>"
    }
    
    /// Format a wire as "fromNode:fromPort ──▶ toNode:toPort".
    private func formatWire(_ wire: Wire, nodeByID: [ObjectID: Node], database: DatabaseLayer) -> String {
        let fromNode = nodeByID[wire.fromNodeID]?.name ?? "?"
        let toNode   = nodeByID[wire.toNodeID]?.name   ?? "?"
        let fromPort = symbolName(symbolID: wire.fromSymbolID, database: database)
        let toPort   = symbolName(symbolID: wire.toSymbolID,   database: database)
        return "\(fromNode):\(fromPort)  ──▶  \(toNode):\(toPort)"
    }
    
    /// Format an output port value with an emoji status prefix.
    func formatOutputPort(_ outputPort: DatabaseModels.OutputPort) -> String {
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

    func nudge() throws {
        for node in try database.node.selectAll() where (try? node.hasOneOrMoreErrorOrPendingOutputs()) == true {
            var node = node
            try node.setScheduledAndSave(true)
        }
    }

    // MARK: printAll

    func printAll() throws {
        let allNodes       = try database.node.selectAll()
        let allWires       = try database.selectAllWires()
        let allDataObjects = try database.selectAllDataObjects()

        // Indexes built once and reused throughout
        let nodeByID: [ObjectID: Node] = Dictionary(
            uniqueKeysWithValues: allNodes.compactMap { node in node.id.map { ($0, node) } })
        let wiresByToNodeID:   [ObjectID: [Wire]] = Dictionary(grouping: allWires, by: \.toNodeID)
        let wiresByFromNodeID: [ObjectID: [Wire]] = Dictionary(grouping: allWires, by: \.fromNodeID)
        
        // MARK: Section 1 — Nodes
        
        printSectionHeader("BUILD GRAPH STATE (\(allNodes.count) nodes)")
        print()
        
        for rawNode in allNodes {
            guard let nodeID = rawNode.id else { continue }
            
            let scheduled = rawNode.scheduled ? "⏱ scheduled" : "idle"
            print("⬢ \(type(of: try rawNode.nodeFunction())) name: \(rawNode.name ?? "<none>") #\(nodeID)  \(scheduled)")
            if let searchKey = rawNode.searchKey {
                let graphShapeNode = try GraphShapeNode.parse(searchKey)
                print("  searchKey:\n\(graphShapeNode.asString(pretty: true, omitOutputPort: true))\n")
            } else {
                print("  searchKey: nil")
            }
            
            if let parentNodeID = rawNode.parentNodeID {
                print("  parent: \(nodeByID[parentNodeID]?.name ?? "?") #\(parentNodeID)")
            }
            
            let descriptor    = (try? rawNode.nodeFunction())?.descriptor
            let inputPorts    = (descriptor?.staticInputPorts  ?? []) + (descriptor?.dynamicInputPorts ?? [])
            let outputPorts   =  descriptor?.outputPorts ?? []
            let incomingWires = wiresByToNodeID[nodeID]   ?? []
            let outgoingWires = wiresByFromNodeID[nodeID] ?? []
            let outputValues  = (try? database.selectAllOutputPorts(nodeID: nodeID)) ?? []
            
            if !inputPorts.isEmpty {
                print("  inputs:")
                for inputPort in inputPorts {
                    let dynamic = descriptor?.dynamicInputPorts.contains(inputPort) == true ? " (dynamic)" : ""
                    let wires   = incomingWires.filter { $0.toSymbolID == inputPort.asSymbolID() }
                    if wires.isEmpty {
                        print("    · \(inputPort)\(dynamic)  — no wires")
                    } else {
                        for wire in wires {
                            let fromNode = nodeByID[wire.fromNodeID]?.name ?? "?"
                            let fromPort = symbolName(symbolID: wire.fromSymbolID, database: database)
                            let outputValue = (try? database.selectOutputPort(nodeID: wire.fromNodeID, nameSymbolID: wire.fromSymbolID)).map { formatOutputPort($0) } ?? "—"
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
        
        // MARK: Section 3 — Data objects
        
        if !allDataObjects.isEmpty {
            printSectionHeader("DATA OBJECTS (\(allDataObjects.count))")
            for dataObject in allDataObjects {
                print("  · 🗄 \(dataObject.content.count) byte(s): \(formatBytes(dataObject.content))")
            }
            print()
        }

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

extension Node {

    fileprivate func printDependencyTree(indentLevel: Int) {
        let indent = String(repeating: "  ", count: indentLevel)
        let nodeFunction = try! nodeFunction()

        let kindName = (try? PolyFactory.type(kind: type(of: nodeFunction).kind))
            .map { String(describing: $0) } ?? "Node"

        let nodeName = name ?? "?"
        print("\(indent)- \(kindName)(\(nodeName))")

        guard let nodeID = id else {
            return
        }

        do {
            let incomingWires = try database.selectWires(goingToNodeID: nodeID)

            var visitedDependencyNodeIDs = Set<ObjectID>()
            var dependencyNodes = [Node]()

            for wire in incomingWires {
                guard !visitedDependencyNodeIDs.contains(wire.fromNodeID) else { continue }
                visitedDependencyNodeIDs.insert(wire.fromNodeID)

                if let rawNode = try? database.node.select(nodeID: wire.fromNodeID) {
                    dependencyNodes.append(rawNode)
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
