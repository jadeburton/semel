
//
//  NodeProtocol.swift
//  build_system
//

import Foundation
import DatabaseModels

// MARK: - Protocols

protocol NodeType: AnyObject, Codable, PolySerializable, WithDefaultInitializer {

    var descriptor: NodeKindDescriptor { get }
    var nodeContext: NodeContext! { get set }

    /// Updates all output values based on the current input values, and also
    /// processes and removes all messages that are queued on any message-stream input ports.
    func process() throws

    func willSave() throws
    func didSave() throws
}

extension NodeType {
    func processWithPreCheck() throws {
        guard allInputsAreSatisfied() else {
            writeToOutputPortsOnError(NodeError.missingInput)
            return
        }
        do {
            try process()
        } catch {
            writeToOutputPortsOnError(error)
        }
    }

    func writeToOutputPortsOnError(_ error: Error) {
        for outputPort in descriptor.outputs {
            try? writeToOutputPort(outputPort, value: .noValue(reason: .error(message: "\(error)")))
        }
    }

    func allInputsAreSatisfied() -> Bool {
        for inputPort in descriptor.inputs {
            if inputPort.minimumConnections > 0 {
                guard let values = try? readAllValuesFromInputPort(inputPort), !values.isEmpty else {
                    return false
                }

                if values.contains(where: { if case .noValue = $0.kind { return true } else { return false } }) {
                    return false
                }
            }
        }

        return true
    }
}

protocol WithDefaultInitializer {
    init() throws
}

protocol MessageType: AnyObject, Codable, PolySerializable {
}

// MARK: - PolyFactory + NodeType

extension PolyFactory {
    /// Construct a default instance of the type identified by `kind`.
    static func makeDefault(kind: UInt) throws -> NodeType {
        try (type(kind: kind) as! (PolySerializable & WithDefaultInitializer).Type).init() as! NodeType
    }
}

// MARK: - NodeContext

struct NodeContext {
    let processingCycle: ProcessingCycle
    var nodeID: ObjectID?           // nil when created in memory but not yet inserted
    var parentNodeID: ObjectID?
    var name: String? {
        didSet {
            assert(name == nil || name!.contains("/") == false)
        }
    }
}

// MARK: - NodeError

enum NodeError: Error {
    case nodeNotFound
    case onlyOneWireShouldBeConnectedToInput
    case missingInput
    case other(message: String)
}

// MARK: - ObjectID helper

extension ObjectID {
    func loadNode(from database: DatabaseLayer) throws -> Node {
        guard let node = try database.selectNodeByID(self) else {
            throw DatabaseLayer.DatabaseError.nodeNotFound
        }
        return node
    }
}

// MARK: - NodeType default implementations

extension NodeType {
    func willSave() throws {}
    func didSave() throws {}
}

extension NodeType {
    func description() -> String {
        "\(String(describing: Self.self)) (kind: \(descriptor.kind)), NodeID: \(nodeContext.nodeID ?? -1), name: \(nodeContext.name ?? "nil"), inputs: \(descriptor.inputs.count), outputs: \(descriptor.outputs.count)"
    }
}

// MARK: - NodeType navigation / port helpers

extension NodeType {
    func parent<N: NodeType>() throws -> N? {
        try nodeContext.processingCycle.parentNode(node: self)
    }

    func save() throws {
        try nodeContext.processingCycle.saveNode(self)
    }

    func buildFullPathName(rootName: String = "root") throws -> String {
        let name = nodeContext.name ?? "<no name>"

        guard let parentNode = try nodeContext.processingCycle.parentNodePoly(node: self) else {
            return name
        }

        if parentNode.nodeContext.name == rootName {
            return ""
        }

        let parentPath = try parentNode.buildFullPathName()

        return parentPath.isEmpty ? name : (parentPath + "/" + name)
    }

    func child(named name: String) throws -> (any NodeType)? {
        try nodeContext.processingCycle.nodePoly(named: name, parentNodeID: nodeContext.nodeID!)
    }

    func delete() throws {
        if let nodeID = nodeContext.nodeID {
            _ = try nodeContext.processingCycle.deleteNode(nodeID)
        }
    }

    func noOutputWiresPreventCascadeDeletion() throws -> Bool {

        guard let wires = try? nodeContext.processingCycle.database.selectWires(comingFromNodeID: nodeContext.nodeID!), !wires.isEmpty else {
            return true
        }

        for wire in wires {
            let toNode = try nodeContext.processingCycle.nodePoly(nodeID: wire.toNodeID)!

            let toNodeAllowsCascadingDelete = toNode.descriptor.inputs.first(where: { $0.index == wire.toPort })?.cascadingDelete ?? false

            if !toNodeAllowsCascadingDelete {
                return false
            }
        }

        return true
    }

    func readAllValuesFromInputPort(_ inputPort: NodeKindDescriptor.InputPort) throws -> [NodeValueAndWire] {
        try nodeContext.processingCycle.readFromInputPort(inputPort, nodeID: nodeContext.nodeID!)
    }

    /// Returning nil means there is nothing yet connected to the input port
    /// (i.e. not that the value is not set).
    func readOneValueFromInputPort(_ inputPort: NodeKindDescriptor.InputPort) throws -> NodeValueAndWire? {
        let values = try readAllValuesFromInputPort(inputPort)

        switch values.count {
        case 0:
            return nil
        case 1:
            return values.first!
        default:
            throw NodeError.onlyOneWireShouldBeConnectedToInput
        }
    }

    func readFromOutputPort(_ outputPort: NodeKindDescriptor.OutputPort) throws -> NodeValue {
        try nodeContext.processingCycle.readFromOutputPort(outputPort, nodeID: nodeContext.nodeID!)
    }

    func writeToOutputPort(_ outputPort: NodeKindDescriptor.OutputPort, value: NodeValueKind) throws {
        try nodeContext.processingCycle.writeToOutputPort(outputPort, value: value, nodeID: nodeContext.nodeID!)
    }

    func writeToOutputPortStream(_ outputPort: NodeKindDescriptor.OutputPort, data: Data) throws {
        try nodeContext.processingCycle.writeToOutputPortStream(outputPort, data: data, nodeID: nodeContext.nodeID!)
    }

    func allChildren() throws -> [NodeType] {
        try nodeContext.processingCycle.allChildNodes(nodeID: nodeContext.nodeID!)
    }

    func childPoly(named name: String, kind: UInt, createIfNotExist: Bool = false) throws -> NodeType? {
        if let existingChild = try nodeContext.processingCycle.nodePoly(named: name, parentNodeID: nodeContext.nodeID!) {
            return existingChild
        }
        if !createIfNotExist { return nil }
        return try nodeContext.processingCycle.makeNodePoly(kind: kind, name: name, parentNodeID: nodeContext.nodeID!)
    }

    /// Creates the child if it does not exist.
    func child<N: NodeType>(named name: String, createIfNotExist: Bool = false) throws -> N? {
        if let existingChild: N = try nodeContext.processingCycle.node(named: name, parentNodeID: nodeContext.nodeID!) {
            return existingChild
        }
        if !createIfNotExist { return nil }
        return try nodeContext.processingCycle.makeNodePoly(kind: N.kind, name: name, parentNodeID: nodeContext.nodeID!) as! N?
    }

    /// Returns a child at a path (e.g. "example/src/main.swift"), this IS recursive.
    func child<N: NodeType>(path: String, createIfNotExist: Bool = false) throws -> N? {
        try nodeContext.processingCycle.childNode(path: path,
                                                  rootNodeID: nodeContext.nodeID!,
                                                  createIfNotExist: createIfNotExist)
    }

    /// Returns a child at a path (e.g. "example/src/main.swift"), this IS recursive.
    func childPoly(path: String, kind: UInt, createIfNotExist: Bool = false) throws -> NodeType? {
        try nodeContext.processingCycle.childNodePoly(path: path,
                                                      rootNodeID: nodeContext.nodeID!,
                                                      kind: kind,
                                                      createIfNotExist: createIfNotExist)
    }

    func findNodeConnectedToNodeViaInputWire(named name: String, fromPort: String) throws -> (any NodeType)? {
        try nodeContext.processingCycle.findNodeConnectedToNodeViaInputWire(self, named: name, fromPort: fromPort)
    }
}

// MARK: - PolySerializable helper

extension PolySerializable {
    func asDataObjectHash() throws -> DataObjectHash {
        (try toJSON()).intern()
    }
}
