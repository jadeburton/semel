//
//  ProcessingCycle.swift
//  build_system
//

import Foundation
import GRDB
import DatabaseModels

// Created to process one Node that has queued messages. Destroyed and recreated for the next
// Node with queued messages. This allows all state related to the processing of one Node's
// messages to be kept in memory and discarded before moving on to the next Node.
final class ProcessingCycle {

    weak var buildEngine: BuildEngine!

    init(buildEngine: BuildEngine?) throws {
        self.buildEngine = buildEngine

        // This is the first object that is created. It resides inside a plugin library that can
        // be configured by the user. The CommandInterpreter is responsible for interpreting the
        // commands sent to the system, e.g. from a CLI or a UI, and translating them into node
        // creations, wire connections, value assignments, etc.
//        rootNode = try rootObject
    }

    func endCycle() throws {
    }
/*
    private func rootObject<N: NodeFunction>() throws -> N {
        let name = "root"
        if let existingNodeRaw = try BuildEngine.shared.database.selectNodesInRoot(named: name).first {
            return try existingNodeRaw.nodeFunctionCast()
        } else {
            return try makeNode(name: name, parentNodeID: nil)
        }
    }*/

    func processOneNode(_ node: Node) throws {
        guard let nodeFunction = try node.nodeFunction() as? NodeFunction else {
            print("WARNING: attempted to process a non-inputtable Node")
            return
        }
        print("process: nodeFunction \(type(of: nodeFunction)), nodeID \(node.id!)")
        try nodeFunction.processWithPreCheck(thisNode: node)
//        try saveNode(node, scheduled: false)
        validatePorts(node: node)
    }

    private func validatePorts(node: Node) {
        assert(
            try! DatabaseLayer.shared.selectAllPorts(nodeID: node.id!).filter { $0.valueKind == .pending }.isEmpty,
            "Not all Ports were processed for node \(node.description())"
        )
    }
}

// MARK: - Node management

extension ProcessingCycle {
    /*
    func allChildNodes(nodeID: ObjectID) throws -> [NodeFunction] {
        try database.selectNodes(parentNodeID: nodeID).map {
            try $0.nodeFunction()
        }
    }

    func parentNode<N: NodeFunction>(node: NodeFunction, nodeContext: NodeContext) throws -> N? {
        if let parentNodeID = nodeContext.parentNodeID {
            let rawNode = try parentNodeID.loadNode(from: database)
            return try rawNode.nodeFunction() as? N
        } else {
            return nil
        }
    }

    func parentNodePoly(node: NodeFunction, nodeContext: NodeContext) throws -> NodeFunction? {
        if let parentNodeID = nodeContext.parentNodeID {
            let rawNode = try parentNodeID.loadNode(from: database)
            let node = try nodeFunction(nodeRaw: rawNode)
            return node
        } else {
            return nil
        }
    }

    func node<N: NodeFunction>(nodeID: ObjectID) throws -> N {
        if let nodeRaw = try database.selectNodeByID(nodeID) {
            return try nodeFunctionCast(nodeRaw: nodeRaw)
        } else {
            throw NodeError.nodeNotFound
        }
    }

    func nodePoly(nodeID: ObjectID) throws -> NodeFunction? {
        if let nodeRaw = try database.selectNodeByID(nodeID) {
            return try nodeFunction(nodeRaw: nodeRaw)
        } else {
            return nil
        }
    }

    func nodePoly(named name: String, parentNodeID: ObjectID) throws -> NodeFunction? {
        if let nodeRaw = try database.selectNodes(named: name, parentNodeID: parentNodeID).first {
            return try nodeFunction(nodeRaw: nodeRaw)
        } else {
            return nil
        }
    }

    func node<N: NodeFunction>(named name: String, parentNodeID: ObjectID) throws -> N? {
        if let nodeRaw = try database.selectNodes(named: name, parentNodeID: parentNodeID).first {
            return try nodeFunctionCast(nodeRaw: nodeRaw)
        } else {
            return nil
        }
    }

    func childNode<N: NodeFunction>(path: String, rootNodeID: ObjectID, createIfNotExist: Bool = false) throws -> N? {
        try childNodePoly(path: path, rootNodeID: rootNodeID, kind: N.kind, createIfNotExist: createIfNotExist)! as? N
    }

*/

//    func makeNode<N: NodeFunction>(name: String?, parentNodeID: ObjectID?) throws -> N {
//        try makeNodeFunctionPoly(kind: N.kind, name: name, parentNodeID: parentNodeID) as! N
//    }
/*
    func makeNodeFunctionPoly(kind: UInt, name: String?, parentNodeID: ObjectID?) throws -> NodeFunction {
        var nodeFunction = try PolyFactory.makeDefault(kind: kind)
//        newObject.nodeContext = .init(processingCycle: self, nodeID: nil, parentNodeID: parentNodeID, name: name)

        var node = Node()
        // Even when a Node is created in memory it is also created on disk. We can always rollback.
        try saveNode(nodeFunction)

        // Create all Ports for the Node, as these should always exist for all non-stream output ports
        try writePendingToAllOutputsOfNode(nodeID: nodeFunction.nodeID)
        return nodeFunction
    }
*/


}

// MARK: - ASCII Art Graph

extension ProcessingCycle {
    func printAll() throws {
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
            let outputValues     = try database.selectAllPorts(nodeID: nodeID)

            var contentLines = [String]()

            if let parentNodeID = rawNode.parentNodeID {
                let parentName = nodeByID[parentNodeID]?.name ?? "?"
                contentLines.append("  parent: \(parentName) #\(parentNodeID)")
            }

            if !inputPorts.isEmpty {
                contentLines.append("  ┌─ inputs ─────────────────────")
                for inputPort in inputPorts {
                    let connectedWires = incomingWires.filter { $0.toSymbolID == inputPort.asSymbolID() }
                    if connectedWires.isEmpty {
                        contentLines.append("  │ ▸ \"\(inputPort)\"  (disconnected)")
                    } else {
                        for wire in connectedWires {
                            let sourceNodeName = nodeByID[wire.fromNodeID]?.name ?? "?"
                            contentLines.append("  │ ▸ \"\(inputPort)\"  ◀── #\(wire.fromNodeID) \"\(sourceNodeName)\" \(try database.selectSymbol(symbolID: wire.fromSymbolID)?.name)")
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
                            contentLines.append("  │ ▹ \"\(outputPort)\"  [\(valueDescription)]  ──▶ #\(wire.toNodeID) \"\(destinationNodeName)\" :\(try database.selectSymbol(symbolID: wire.toSymbolID))")
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
                let fromNodeName = nodeByID[wire.fromNodeID]?.name ?? "?"
                let toNodeName   = nodeByID[wire.toNodeID]?.name ?? "?"
                try print("  \"\(fromNodeName)\" \(database.selectSymbol(symbolID: wire.fromSymbolID)?.name)  ───▶  \"\(toNodeName)\" :\(database.selectSymbol(symbolID: wire.toSymbolID))")
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

      //  try rootNode.debugPrintTree()
    }
}

