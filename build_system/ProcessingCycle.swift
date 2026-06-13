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
    let database: DatabaseLayer
    var rootNode: RootNode!
//    private var loadedNodes = [ObjectID: NodeType]()

    var wiresModified = false

    init(database: DatabaseLayer, buildEngine: BuildEngine?) throws {
        self.database = database
        self.buildEngine = buildEngine

        // This is the first object that is created. It resides inside a plugin library that can
        // be configured by the user. The CommandInterpreter is responsible for interpreting the
        // commands sent to the system, e.g. from a CLI or a UI, and translating them into node
        // creations, wire connections, value assignments, etc.
        rootNode = try rootObject()
    }

    func endCycle() throws {
//        for (_, node) in loadedNodes {
//            try node.save()
//        }
    }

    private func rootObject<N: NodeType>() throws -> N {
        let name = "root"
        if let existingNodeRaw = try database.selectNodesInRoot(named: name).first {
            return try wrapRawNode(nodeRaw: existingNodeRaw)
        } else {
            return try makeNode(name: name, parentNodeID: nil)
        }
    }
}

// MARK: - Node management

extension ProcessingCycle {
    func allChildNodes(nodeID: ObjectID) throws -> [NodeType] {
        try database.selectNodes(parentNodeID: nodeID).map {
            try wrapRawNodePoly(nodeRaw: $0)
        }
    }

    func parentNode<N: NodeType>(node: NodeType) throws -> N? {
        if let parentNodeID = node.nodeContext.parentNodeID {
            let rawNode = try parentNodeID.loadNode(from: node.nodeContext.processingCycle.database)
            let node = try node.nodeContext.processingCycle.wrapRawNodePoly(nodeRaw: rawNode)
            return node as? N
        } else {
            return nil
        }
    }

    func parentNodePoly(node: NodeType) throws -> NodeType? {
        if let parentNodeID = node.nodeContext.parentNodeID {
            let rawNode = try parentNodeID.loadNode(from: node.nodeContext.processingCycle.database)
            let node = try node.nodeContext.processingCycle.wrapRawNodePoly(nodeRaw: rawNode)
            return node
        } else {
            return nil
        }
    }

    func node<N: NodeType>(nodeID: ObjectID) throws -> N {
        if let nodeRaw = try database.selectNodeByID(nodeID) {
            return try wrapRawNode(nodeRaw: nodeRaw)
        } else {
            throw NodeError.nodeNotFound
        }
    }

    func nodePoly(nodeID: ObjectID) throws -> NodeType? {
        if let nodeRaw = try database.selectNodeByID(nodeID) {
            return try wrapRawNodePoly(nodeRaw: nodeRaw)
        } else {
            return nil
        }
    }

    func nodePoly(named name: String, parentNodeID: ObjectID) throws -> NodeType? {
        if let nodeRaw = try database.selectNodes(named: name, parentNodeID: parentNodeID).first {
            return try wrapRawNodePoly(nodeRaw: nodeRaw)
        } else {
            return nil
        }
    }

    func node<N: NodeType>(named name: String, parentNodeID: ObjectID) throws -> N? {
        if let nodeRaw = try database.selectNodes(named: name, parentNodeID: parentNodeID).first {
            return try wrapRawNode(nodeRaw: nodeRaw)
        } else {
            return nil
        }
    }

    func childNode<N: NodeType>(path: String, rootNodeID: ObjectID, createIfNotExist: Bool = false) throws -> N? {
        try childNodePoly(path: path, rootNodeID: rootNodeID, kind: N.kind, createIfNotExist: createIfNotExist)! as? N
    }

    func childNodePoly(path: String, rootNodeID: ObjectID, kind: UInt, createIfNotExist: Bool = false) throws -> NodeType? {
        let components = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        var currentNodeID = rootNodeID

        for (index, name) in components.enumerated() {
            guard let rawNode = try? database.selectNodes(named: name, parentNodeID: currentNodeID).first else {
                if !createIfNotExist { return nil }
                return try makeNodePoly(kind: kind, name: name, parentNodeID: currentNodeID)
            }

            if index == components.count - 1 {
                return try? wrapRawNodePoly(nodeRaw: rawNode)
            } else {
                currentNodeID = rawNode.id!
            }
        }

        return try wrapRawNodePoly(nodeRaw: rootNodeID.loadNode(from: database))
    }

    func wrapRawNode<N: NodeType>(nodeRaw: Node) throws -> N {
        try wrapRawNodePoly(nodeRaw: nodeRaw) as! N
    }

    func wrapRawNodePoly(nodeRaw: Node) throws -> NodeType {
        let node = try PolyFactory.decode(encodedJSON: nodeRaw.configuration!) as! NodeType
        node.nodeContext = .init(processingCycle: self, nodeID: nodeRaw.id!, parentNodeID: nodeRaw.parentNodeID, name: nodeRaw.name, searchKey: nodeRaw.searchKey)
//        loadedNodes[nodeRaw.id!] = node
        return node
    }

    func makeNode<N: NodeType>(name: String?, parentNodeID: ObjectID?) throws -> N {
        try makeNodePoly(kind: N.kind, name: name, parentNodeID: parentNodeID) as! N
    }

    func makeNodePoly(kind: UInt, name: String?, parentNodeID: ObjectID?) throws -> NodeType {
        let newObject = try PolyFactory.makeDefault(kind: kind)
        newObject.nodeContext = .init(processingCycle: self, nodeID: nil, parentNodeID: parentNodeID, name: name)

        // Even when a Node is created in memory it is also created on disk. We can always rollback.
        try saveNode(newObject)
        //loadedNodes[newObject.nodeContext.nodeID!] = newObject

        // Create all NodeOutputValues for the Node, as these should always exist for all non-stream output ports
        try writePendingToAllOutputsOfNode(nodeID: newObject.nodeContext.nodeID!)
        return newObject
    }

    func scheduleNode(_ nodeID: ObjectID) throws {
        var existing = try database.selectNodeByID(nodeID)!
        existing.scheduled = true
        try database.updateNode(existing)
        BuildEngine.shared.signalWorkAvailable()
    }

    func saveNode(_ node: NodeType, scheduled: Bool? = nil) throws {
        try node.willSave()

        if let nodeID = node.nodeContext.nodeID {
            let existing = try database.selectNodeByID(nodeID)!
            try database.updateNode(.init(id: nodeID,
                                          parentNodeID: node.nodeContext.parentNodeID,
                                          kind: node.descriptor.kind,
                                          name: node.nodeContext.name,
                                          configuration: node.toJSON(),
                                          scheduled: scheduled == nil ? existing.scheduled : scheduled!,
                                          searchKey: node.nodeContext.searchKey))
        } else {
            node.nodeContext.nodeID = try database.insertNode(.init(parentNodeID: node.nodeContext.parentNodeID,
                                                                    kind: node.descriptor.kind,
                                                                    name: node.nodeContext.name,
                                                                    configuration: node.toJSON(),
                                                                    scheduled: true,
                                                                    searchKey: node.nodeContext.searchKey)) // trigger first "process" iteration to complete init process
        }

        try node.didSave()
    }

    func deleteNode(_ nodeID: ObjectID) throws -> Bool {
        print("delete node #\(nodeID)")

        for wire in try database.selectWires(goingToNodeID: nodeID) {
            _ = try deleteWire(wire)
        }

        for wire in try database.selectWires(comingFromNodeID: nodeID) {
            _ = try deleteWire(wire)
        }

        let nodeOutputValueDeleteCount = try database.deleteNodeOutputValues(nodeID: nodeID)

        print("\(nodeOutputValueDeleteCount) NodeOutputValue(s) deleted for node #\(nodeID)")

        //defer { loadedNodes[nodeID] = nil }

        return try database.deleteNode(nodeID: nodeID) && nodeOutputValueDeleteCount > 0
    }
}

// MARK: - Node processing

extension ProcessingCycle {
    func processOneNode(_ rawNode: Node) throws {
        let node = try wrapRawNodePoly(nodeRaw: rawNode)
        print("process: node \(type(of: node)), nodeID \(rawNode.id!)")
        try node.processWithPreCheck()
        try saveNode(node, scheduled: false)
        validateNodeOutputValues(node: node)
    }

    private func validateNodeOutputValues(node: NodeType) {
        assert(
            try! database.selectAllNodeOutputValues(nodeID: node.nodeContext.nodeID!).filter { $0.kind == .pending }.isEmpty,
            "Not all NodeOutputValues were processed for node \(node.description())"
        )
    }
}

// MARK: - Port management

extension ProcessingCycle {
    func readFromOutputPort(_ outputPort: OutputPort, nodeID: ObjectID) throws -> NodeValue {
        guard let nodeOutputValue = try database.selectNodeOutputValue(nodeID: nodeID, port: outputPort.index) else {
            return .init(originNodeID: nodeID, originOutputPort: outputPort.index, kind: .noValue(reason: .error(message: "No value ever existed")))
        }
        return try nodeOutputValue.asNodeOutputValue()
    }

    func readFromInputPort(_ inputPort: InputPort, nodeID: ObjectID) throws -> [NodeValueAndWire] {
        let wiresOnThisInput = try database.selectWires(goingToNodeID: nodeID, toPort: inputPort.index)

        return try wiresOnThisInput.compactMap { wire in
            if let nodeOutputValue = try database.selectNodeOutputValue(nodeID: wire.fromNodeID, port: wire.fromPort) {
                return try nodeOutputValue.asNodeOutputValue(wire: wire)
            } else {
                return nil
            }
        }
    }

    func writePendingToAllOutputsOfNode(nodeID: ObjectID) throws {
        let node = try nodePoly(nodeID: nodeID)!

        for output in node.descriptor.outputs {
            if case .value = output.kind {
                try node.writeToOutputPort(output, value: .noValue(reason: .pending))
            }
        }
    }

    @discardableResult func writeToOutputPort(_ outputPort: OutputPort,
                           value: NodeValueKind,
                           nodeID: ObjectID) throws -> Bool {

        try writeToOutputPort(nodeOutputValue: try value.mapNodeOutputValue(nodeID: nodeID, outputPortIndex: outputPort.index),
                              nodeID: nodeID,
                              outputPort: outputPort.index)
    }

    @discardableResult func writeToOutputPort(nodeOutputValue: NodeOutputValue, nodeID: ObjectID, outputPort: UInt8) throws -> Bool {

        if let existing = try database.selectNodeOutputValue(nodeID: nodeID, port: outputPort) {
            if existing == nodeOutputValue {
                print("No change to NodeOutputValue, ignoring")
                return false
            }
        }

        try database.insertOrReplaceNodeOutputValue(nodeOutputValue)

        for wire in try database.selectWires(comingFromNodeID: nodeID, fromPort: outputPort) {
            try writePendingToAllOutputsOfNode(nodeID: wire.toNodeID)
            if nodeOutputValue.kind != .pending {
                try scheduleNode(wire.toNodeID)
            }
        }
        return true
    }
}

// MARK: - ASCII Art Graph

extension ProcessingCycle {
    func printAll() throws {
        let allNodes        = try database.selectAllNodes()
        let allWires        = try database.selectAllWires()
        let allOutputValues = try database.selectAllNodeOutputValues(limit: 10_000_000)
        let allDataObjects  = try database.selectAllDataObjects()

        // Index helpers
        let nodeByID: [ObjectID: Node] = Dictionary(
            uniqueKeysWithValues: allNodes.compactMap { node in node.id.map { ($0, node) } })
        let outputValuesByNodeID: [ObjectID: [DatabaseModels.NodeOutputValue]] =
            Dictionary(grouping: allOutputValues, by: { $0.nodeID })
        let wiresByFromNodeID: [ObjectID: [Wire]] = Dictionary(grouping: allWires, by: { $0.fromNodeID })
        let wiresByToNodeID:   [ObjectID: [Wire]] = Dictionary(grouping: allWires, by: { $0.toNodeID })

        func descriptorFor(_ rawNode: Node) -> NodeKindDescriptor? {
            guard let node = try? wrapRawNodePoly(nodeRaw: rawNode) else { return nil }
            return node.descriptor
        }

        func labelForNode(_ rawNode: Node) -> String {
            let name = rawNode.name ?? "?"
            let kindName = (try? PolyFactory.type(kind: rawNode.kind))
                .map { String(describing: $0) } ?? "kind:\(rawNode.kind)"
            return "\(name) [\(kindName)] #\(rawNode.id ?? -1) scheduled: \(rawNode.scheduled) searchKey: '\(rawNode.searchKey ?? "nil")'"
        }

        func formatOutputValue(_ outputValue: DatabaseModels.NodeOutputValue) -> String {
            switch outputValue.kind {
            case .value:
                let hash = outputValue.dataObjectHash ?? "nil"
                let shortHash = hash.count > 12 ? String(hash.prefix(12)) + "…" : hash
                return "✔ '\(shortHash)'"
            case .pending:
                return "⏳ pending"
            case .error:
                let hash = outputValue.dataObjectHash ?? "nil"
                let shortHash = hash.count > 12 ? String(hash.prefix(12)) + "…" : hash
                return "❌ error '\(outputValue.errorMessage ?? "<no message>")' hash '\(shortHash)'"
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
            let inputPorts       = descriptor?.inputs  ?? []
            let outputPorts      = descriptor?.outputs ?? []
            let incomingWires    = wiresByToNodeID[nodeID]   ?? []
            let outgoingWires    = wiresByFromNodeID[nodeID] ?? []
            let outputValues     = outputValuesByNodeID[nodeID] ?? []

            var contentLines = [String]()

            if let parentNodeID = rawNode.parentNodeID {
                let parentName = nodeByID[parentNodeID]?.name ?? "?"
                contentLines.append("  parent: \(parentName) #\(parentNodeID)")
            }

            if !inputPorts.isEmpty {
                contentLines.append("  ┌─ inputs ─────────────────────")
                for inputPort in inputPorts {
                    let connectedWires = incomingWires.filter { $0.toPort == inputPort.index }
                    if connectedWires.isEmpty {
                        contentLines.append("  │ ▸ :\(inputPort.index) \"\(inputPort.name)\"  (disconnected)")
                    } else {
                        for wire in connectedWires {
                            let sourceNodeName = nodeByID[wire.fromNodeID]?.name ?? "?"
                            contentLines.append("  │ ▸ :\(inputPort.index) \"\(inputPort.name)\"  ◀── #\(wire.fromNodeID) \"\(sourceNodeName)\" :\(wire.fromPort)")
                        }
                    }
                }
                contentLines.append("  └─────────────────────────────")
            }

            if !outputPorts.isEmpty {
                contentLines.append("  ┌─ outputs ────────────────────")
                for outputPort in outputPorts {
                    let connectedWires = outgoingWires.filter { $0.fromPort == outputPort.index }
                    let outputValue = outputValues.first(where: { $0.port == outputPort.index })
                    let valueDescription = outputValue.map { formatOutputValue($0) } ?? "<missing>"
                    if connectedWires.isEmpty {
                        contentLines.append("  │ ▹ :\(outputPort.index) \"\(outputPort.name)\"  [\(valueDescription)]  (no wires)")
                    } else {
                        for wire in connectedWires {
                            let destinationNodeName = nodeByID[wire.toNodeID]?.name ?? "?"
                            contentLines.append("  │ ▹ :\(outputPort.index) \"\(outputPort.name)\"  [\(valueDescription)]  ──▶ #\(wire.toNodeID) \"\(destinationNodeName)\" :\(wire.toPort)")
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
                print("  \"\(fromNodeName)\" :\(wire.fromPort)  ───▶  \"\(toNodeName)\" :\(wire.toPort)")
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
        if !allOutputValues.isEmpty {
            print("──────────────────────────────────────────────")
            print("  OUTPUT VALUES (\(allOutputValues.count))")
            print("──────────────────────────────────────────────")
            for outputValue in allOutputValues {
                if let node = nodeByID[outputValue.nodeID] { // BUG: the node should always be found, but if not, we should handle it more gracefully than crashing
                    let nodeDecoded = try! PolyFactory.decode(encodedJSON: node.configuration!) as! NodeType
                    let matchingOutputPort = nodeDecoded.descriptor.outputs.first(where: { $0.index == outputValue.port })
                    let outputPortName = matchingOutputPort?.name ?? ":\(outputValue.port)"
                    print("  \(type(of: nodeDecoded)) \"\(node.name ?? "?")\" #\(outputValue.nodeID) \(outputPortName) (\(outputValue.port))  → \(formatOutputValue(outputValue))")
                } else {
                    print("  <deleted> nodeID = #\(outputValue.nodeID) port = \(outputValue.port)  → \(formatOutputValue(outputValue))")
                }
            }
            print("──────────────────────────────────────────────")
            print()
        }

        try rootNode.buildGraph.debugPrintTree()
    }
}

