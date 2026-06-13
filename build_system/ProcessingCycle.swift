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
//    private var loadedNodes = [ObjectID: NodeFunction]()

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

    private func rootObject<N: NodeFunction>() throws -> N {
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
    func allChildNodes(nodeID: ObjectID) throws -> [NodeFunction] {
        try database.selectNodes(parentNodeID: nodeID).map {
            try wrapRawNodePoly(nodeRaw: $0)
        }
    }

    func parentNode<N: NodeFunction>(node: NodeFunction) throws -> N? {
        if let parentNodeID = node.nodeContext.parentNodeID {
            let rawNode = try parentNodeID.loadNode(from: node.nodeContext.processingCycle.database)
            let node = try node.nodeContext.processingCycle.wrapRawNodePoly(nodeRaw: rawNode)
            return node as? N
        } else {
            return nil
        }
    }

    func parentNodePoly(node: NodeFunction) throws -> NodeFunction? {
        if let parentNodeID = node.nodeContext.parentNodeID {
            let rawNode = try parentNodeID.loadNode(from: node.nodeContext.processingCycle.database)
            let node = try node.nodeContext.processingCycle.wrapRawNodePoly(nodeRaw: rawNode)
            return node
        } else {
            return nil
        }
    }

    func node<N: NodeFunction>(nodeID: ObjectID) throws -> N {
        if let nodeRaw = try database.selectNodeByID(nodeID) {
            return try wrapRawNode(nodeRaw: nodeRaw)
        } else {
            throw NodeError.nodeNotFound
        }
    }

    func nodePoly(nodeID: ObjectID) throws -> NodeFunction? {
        if let nodeRaw = try database.selectNodeByID(nodeID) {
            return try wrapRawNodePoly(nodeRaw: nodeRaw)
        } else {
            return nil
        }
    }

    func nodePoly(named name: String, parentNodeID: ObjectID) throws -> NodeFunction? {
        if let nodeRaw = try database.selectNodes(named: name, parentNodeID: parentNodeID).first {
            return try wrapRawNodePoly(nodeRaw: nodeRaw)
        } else {
            return nil
        }
    }

    func node<N: NodeFunction>(named name: String, parentNodeID: ObjectID) throws -> N? {
        if let nodeRaw = try database.selectNodes(named: name, parentNodeID: parentNodeID).first {
            return try wrapRawNode(nodeRaw: nodeRaw)
        } else {
            return nil
        }
    }

    func childNode<N: NodeFunction>(path: String, rootNodeID: ObjectID, createIfNotExist: Bool = false) throws -> N? {
        try childNodePoly(path: path, rootNodeID: rootNodeID, kind: N.kind, createIfNotExist: createIfNotExist)! as? N
    }

    func childNodePoly(path: String, rootNodeID: ObjectID, kind: UInt, createIfNotExist: Bool = false) throws -> NodeFunction? {
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

    func wrapRawNode<N: NodeFunction>(nodeRaw: Node) throws -> N {
        try wrapRawNodePoly(nodeRaw: nodeRaw) as! N
    }

    func wrapRawNodePoly(nodeRaw: Node) throws -> NodeFunction {
        let node = try PolyFactory.decode(encodedJSON: nodeRaw.configuration!) as! NodeFunction
        node.nodeContext = .init(processingCycle: self, nodeID: nodeRaw.id!, parentNodeID: nodeRaw.parentNodeID, name: nodeRaw.name, searchKey: nodeRaw.searchKey)
//        loadedNodes[nodeRaw.id!] = node
        return node
    }

    func makeNode<N: NodeFunction>(name: String?, parentNodeID: ObjectID?) throws -> N {
        try makeNodePoly(kind: N.kind, name: name, parentNodeID: parentNodeID) as! N
    }

    func makeNodePoly(kind: UInt, name: String?, parentNodeID: ObjectID?) throws -> NodeFunction {
        let newObject = try PolyFactory.makeDefault(kind: kind)
        newObject.nodeContext = .init(processingCycle: self, nodeID: nil, parentNodeID: parentNodeID, name: name)

        // Even when a Node is created in memory it is also created on disk. We can always rollback.
        try saveNode(newObject)
        //loadedNodes[newObject.nodeID] = newObject

        // Create all Ports for the Node, as these should always exist for all non-stream output ports
        try writePendingToAllOutputsOfNode(nodeID: newObject.nodeID)
        return newObject
    }

    func scheduleNode(_ nodeID: ObjectID) throws {
        var existing = try database.selectNodeByID(nodeID)!
        existing.scheduled = true
        try database.updateNode(existing)
        BuildEngine.shared.signalWorkAvailable()
    }

    func saveNode(_ node: NodeFunction, scheduled: Bool? = nil) throws {
        try node.willSave()

        if let nodeID = node.nodeContext.nodeID {
            let existing = try database.selectNodeByID(nodeID)!
            try database.updateNode(.init(id: nodeID,
                                          parentNodeID: node.nodeContext.parentNodeID,
                                          kind: type(of: node).kind,
                                          name: node.nodeContext.name,
                                          configuration: node.toJSON(),
                                          scheduled: scheduled == nil ? existing.scheduled : scheduled!,
                                          searchKey: node.nodeContext.searchKey))
        } else {
            node.nodeContext.nodeID = try database.insertNode(.init(parentNodeID: node.nodeContext.parentNodeID,
                                                                    kind: type(of: node).kind,
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

        let portDeleteCount = try database.deletePorts(nodeID: nodeID)

        print("\(portDeleteCount) Port(s) deleted for node #\(nodeID)")

        //defer { loadedNodes[nodeID] = nil }

        return try database.deleteNode(nodeID: nodeID) && portDeleteCount > 0
    }
}

// MARK: - Node processing

extension ProcessingCycle {
    func processOneNode(_ rawNode: Node) throws {
        let node = try wrapRawNodePoly(nodeRaw: rawNode)
        print("process: node \(type(of: node)), nodeID \(rawNode.id!)")
        try node.processWithPreCheck()
        try saveNode(node, scheduled: false)
        validatePorts(node: node)
    }

    private func validatePorts(node: NodeFunction) {
        assert(
            try! database.selectAllPorts(nodeID: node.nodeID).filter { $0.valueKind == .pending }.isEmpty,
            "Not all Ports were processed for node \(node.description())"
        )
    }
}

// MARK: - Port management

extension ProcessingCycle {
    func readFromOutputPort(_ outputPort: String, nodeID: ObjectID) throws -> NodeValue {
        let outputPortNameID = outputPort.asPortNameID()

        guard let port = try database.selectPort(nodeID: nodeID, portNameID: outputPortNameID) else {
            return .init(originNodeID: nodeID, originOutputPortNameID: outputPortNameID, kind: .noValue(reason: .error(message: "No value ever existed")))
        }
        return try port.asPort()
    }

    func readFromInputPort(_ inputPort: String, nodeID: ObjectID) throws -> [String: NodeValueAndWire] {
        let inputPortNameID = inputPort.asPortNameID()

        let wiresOnThisInput = try database.selectWires(goingToNodeID: nodeID, toPortNameID: inputPortNameID)

        return try wiresOnThisInput.compactMap { wire in
            if let port = try database.selectPort(nodeID: wire.fromNodeID, portNameID: wire.fromPortNameID) {
                return (wire.name.resolvePortName(), try port.asPort(wire: wire))
            } else {
                return nil
            }
        }
    }

    func writePendingToAllOutputsOfNode(nodeID: ObjectID) throws {
        let node = try nodePoly(nodeID: nodeID)!

        for output in node.descriptor.staticOutputPorts {
            try node.writeToOutputPort(output, value: .noValue(reason: .pending))
        }
    }

    @discardableResult func writeToOutputPort(_ outputPort: String,
                                              value: NodeValueKind,
                                              nodeID: ObjectID) throws -> Bool {

        try writeToOutputPort(port: try value.mapPort(nodeID: nodeID,
                                                      outputPortNameID: outputPort.asPortNameID()),
                              nodeID: nodeID)
    }

    @discardableResult func writeToOutputPort(port: build_system.Port,
                                              nodeID: ObjectID) throws -> Bool {

        if let existing = try database.selectPort(nodeID: nodeID, portNameID: port.portNameID) {
            if existing == port {
                print("No change to Port, ignoring")
                return false
            }
        }

        try database.insertOrUpdatePort(port)

        for wire in try database.selectWires(comingFromNodeID: nodeID, fromPortNameID: port.portNameID) {
            try writePendingToAllOutputsOfNode(nodeID: wire.toNodeID)
            if port.valueKind != .pending {
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
        //let allOutputValues = try database.selectAllPorts(limit: 10_000_000)
        let allDataObjects  = try database.selectAllDataObjects()

        // Index helpers
        let nodeByID: [ObjectID: Node] = Dictionary(
            uniqueKeysWithValues: allNodes.compactMap { node in node.id.map { ($0, node) } })
//        let outputValuesByNodeID: [ObjectID: [DatabaseModels.Port]] =
//            Dictionary(grouping: allOutputValues, by: { $0.nodeID })
        let wiresByFromNodeID: [ObjectID: [Wire]] = Dictionary(grouping: allWires, by: { $0.fromNodeID })
        let wiresByToNodeID:   [ObjectID: [Wire]] = Dictionary(grouping: allWires, by: { $0.toNodeID })

        func descriptorFor(_ rawNode: Node) -> NodeFunctionDescriptor? {
            guard let node = try? wrapRawNodePoly(nodeRaw: rawNode) else { return nil }
            return node.descriptor
        }

        func labelForNode(_ rawNode: Node) -> String {
            let name = rawNode.name ?? "?"
            let kindName = (try? PolyFactory.type(kind: rawNode.kind))
                .map { String(describing: $0) } ?? "kind:\(rawNode.kind)"
            return "\(name) [\(kindName)] #\(rawNode.id ?? -1) scheduled: \(rawNode.scheduled) searchKey: '\(rawNode.searchKey ?? "nil")'"
        }

        func formatOutputValue(_ outputValue: DatabaseModels.Port) -> String {
            switch outputValue.valueKind {
            case .notApplicable:
                return " (not applicable, is input)"
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
            let inputPorts       = descriptor?.staticInputPorts  ?? []
            let outputPorts      = descriptor?.staticOutputPorts ?? []
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
                    let connectedWires = incomingWires.filter { $0.toPortNameID == inputPort.asPortNameID() }
                    if connectedWires.isEmpty {
                        contentLines.append("  │ ▸ \"\(inputPort)\"  (disconnected)")
                    } else {
                        for wire in connectedWires {
                            let sourceNodeName = nodeByID[wire.fromNodeID]?.name ?? "?"
                            contentLines.append("  │ ▸ \"\(inputPort)\"  ◀── #\(wire.fromNodeID) \"\(sourceNodeName)\" \(try database.selectPortName(portNameID: wire.fromPortNameID)?.name)")
                        }
                    }
                }
                contentLines.append("  └─────────────────────────────")
            }

            if !outputPorts.isEmpty {
                contentLines.append("  ┌─ outputs ────────────────────")
                for outputPort in outputPorts {
                    let outputPortNameID = outputPort.asPortNameID()
                    let connectedWires = outgoingWires.filter { $0.fromPortNameID == outputPortNameID }
                    let outputValue = outputValues.first(where: { $0.portNameID == outputPortNameID }) // ?
                    let valueDescription = outputValue.map { formatOutputValue($0) } ?? "<missing>"
                    if connectedWires.isEmpty {
                        contentLines.append("  │ ▹ \"\(outputPort)\"  [\(valueDescription)]  (no wires)")
                    } else {
                        for wire in connectedWires {
                            let destinationNodeName = nodeByID[wire.toNodeID]?.name ?? "?"
                            contentLines.append("  │ ▹ \"\(outputPort)\"  [\(valueDescription)]  ──▶ #\(wire.toNodeID) \"\(destinationNodeName)\" :\(try database.selectPortName(portNameID: wire.toPortNameID))")
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
                try print("  \"\(fromNodeName)\" \(database.selectPortName(portNameID: wire.fromPortNameID)?.name)  ───▶  \"\(toNodeName)\" :\(database.selectPortName(portNameID: wire.toPortNameID))")
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
                    let outputPortName = matchingOutputPort?.name ?? ":\(outputValue.port)"
                    print("  \(type(of: nodeDecoded)) \"\(node.name ?? "?")\" #\(outputValue.nodeID) \(outputPortName) (\(outputValue.port))  → \(formatOutputValue(outputValue))")
                } else {
                    print("  <deleted> nodeID = #\(outputValue.nodeID) port = \(outputValue.port)  → \(formatOutputValue(outputValue))")
                }
            }
            print("──────────────────────────────────────────────")
            print()
        }*/

        try rootNode.debugPrintTree()
    }
}

