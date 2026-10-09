// NodeError.swift
// SemelNodeKit
//
// The errors a node can throw. Part of the node-authoring API rather than the
// engine: a node reports these, and the engine decides what to do about them.
//
// A node's own failure reaches its ports as an `ErrorDocument`, through the condition each
// case names (`errorCondition`); the client renders it. The descriptions are for what does
// not travel as a document — a request the server refuses, a line in the log.

import SemelDatabaseModels

public enum NodeError: Error, CustomStringConvertible, ErrorConditionConvertible {
    case nodeNotFound
    /// A node holding no row for an output port its type declares. Every node is given one
    /// per declared port when it is created, so this is a graph something damaged — not a
    /// port that has yet to be written, which holds a state of its own.
    case outputPortMissing(nodeID: ObjectID, port: String)
    /// A node reading an input port that is not in what it was given to process. Every port
    /// its type declares is there, holding no wires when none is wired, so this is a node
    /// asking for a port by a name its own descriptor does not declare.
    case inputPortMissing(port: String)
    /// A required input port with no wire, met inside `process`. The engine processes a
    /// node only once each of its required ports has a wire, so this is a graph changed
    /// since — or a node reading a port as required that its descriptor calls optional.
    case requiredInputPortUnwired(port: String)
    /// A node whose record lacks a property its type is always created with — the `path`
    /// of a file-system node. Nothing makes such a node, so its row has been damaged.
    case propertyMissing(kind: UInt, nodeID: ObjectID?, property: String)
    /// More than one wire on an input port that takes one, by the port and the wires'
    /// names, sorted (B-141). Thrown by `ProcessInput.onlyWire` for every node, so a port
    /// declared to hold one wire never picks one of several by dictionary order. For the
    /// settings nodes it is also the rule that two sets of settings meet only in a
    /// `ConfigMerger`, whose `base` and `override` state which wins: a port that folded its
    /// wires together in key order would be a second merge with no stated precedence (B-120).
    case severalWiresOnOneWirePort(port: String, wires: [String])
    /// Thrown by `expectValue()` when the value asked for is not there to be had. These
    /// three are control flow rather than messages: the engine turns each into the
    /// `NoValueReason` the node publishes, before anything is written to a port, so a node
    /// stopped by one of them says so by its state.
    case inputValueInError
    case inputValuePending
    /// Thrown when an input has never had a value and nothing has failed to make one.
    case inputValueNotProduced
    case processNotSupported
    case cannotHaveProperties
    case cannotDeleteNodeWithOutputs
    case graphSpecBadIntegrity(currentShapeNode: String, expectedShapeNode: String, log: String)
    /// Two children of one folder may never share a name. The tree is walked by name, so
    /// a duplicate makes every path through that folder ambiguous — `childNode` would
    /// take whichever the database returned first.
    case nameCollision(path: String, existingKind: UInt)
    /// A source — a node declaring no input ports — asked to process. Never reached in a
    /// working graph: nothing schedules a source.
    case sourceCannotProcess(type: String)
    /// A path in a file system with no folder at it.
    case noSuchFolder(path: String)
    /// A folder's child of a kind a listing does not know.
    case unexpectedNodeKind(kind: UInt)
    /// A folder that cannot be deleted because a child below it is not deletable; `path`
    /// when it is known.
    case folderNotDeletable(path: String?)
    /// A node asked to make folders below itself that is not a folder.
    case notAFolder(kind: UInt)
    /// A node with no name, where one is needed: a path is built from names.
    case nodeHasNoName(nodeID: ObjectID?)

    /// The state the engine writes to every output port of a node this error stopped, or
    /// nil when the error is the node's own and reaches the port as its document.
    ///
    /// Spelled out case by case rather than with a `default`, so that a case added here with
    /// a state behind it has to say which one, instead of being published as an error.
    public var publishedState: NoValueReason? {
        switch self {
        case .inputValuePending:     return .pending
        case .inputValueNotProduced: return .inputNotProduced
        case .inputValueInError:     return .inputInError

        case .nodeNotFound,
             .outputPortMissing,
             .inputPortMissing,
             .requiredInputPortUnwired,
             .propertyMissing,
             .severalWiresOnOneWirePort,
             .processNotSupported,
             .cannotHaveProperties,
             .cannotDeleteNodeWithOutputs,
             .graphSpecBadIntegrity,
             .nameCollision,
             .sourceCannotProcess,
             .noSuchFolder,
             .unexpectedNodeKind,
             .folderNotDeletable,
             .notAFolder,
             .nodeHasNoName:
            return nil
        }
    }

    public var errorCondition: ErrorCondition {
        switch self {
        case .nodeNotFound:
            return .nodeNotFound
        case .outputPortMissing(let nodeID, let port):
            return .outputPortMissing(nodeID: nodeID, port: port)
        case .inputPortMissing(let port):
            return .portNotDeclared(type: nil, port: port)
        case .requiredInputPortUnwired(let port):
            return .requiredPortUnwired(type: nil, port: port)
        case .propertyMissing(let kind, let nodeID, let property):
            return .nodePropertyMissing(kind: kind, nodeID: nodeID, property: property)
        case .severalWiresOnOneWirePort(let port, let wires):
            return .severalWiresOnOneWirePort(type: nil, port: port, wires: wires)
        // Never published as errors (`publishedState`); named for a caller that asks anyway.
        case .inputValueInError, .inputValuePending, .inputValueNotProduced:
            return .inputInError
        case .processNotSupported:
            return .processNotSupported(type: nil)
        case .cannotHaveProperties:
            return .cannotHaveProperties
        case .cannotDeleteNodeWithOutputs:
            return .cannotDeleteNodeWithOutputs
        case .graphSpecBadIntegrity(let current, let expected, let log):
            return .graphSpecBadIntegrity(found: current, expected: expected, log: log)
        case .nameCollision(let path, let existingKind):
            return .nameCollision(path: path, existingKind: existingKind)
        case .sourceCannotProcess(let type):
            return .sourceCannotProcess(type: type)
        case .noSuchFolder(let path):
            return .noSuchFolder(path: path)
        case .unexpectedNodeKind(let kind):
            return .unexpectedNodeKind(kind: kind)
        case .folderNotDeletable(let path):
            return .folderNotDeletable(path: path)
        case .notAFolder(let kind):
            return .unexpectedNodeKind(kind: kind)
        case .nodeHasNoName(let nodeID):
            return .nodeHasNoName(kind: nil, nodeID: nodeID)
        }
    }

    public var description: String {
        switch self {
        case .nodeNotFound:
            return "there is no such node"
        case .outputPortMissing(let nodeID, let port):
            return "node #\(nodeID) holds no row for its output port '\(port)', which its type declares, so the "
                 + "graph is damaged; `check` names every such port and `reset` rebuilds the graph"
        case .inputPortMissing(let port):
            return "this node read input port '\(port)', which its type does not declare"
        case .requiredInputPortUnwired(let port):
            return "required input port '\(port)' has no wire"
        case .propertyMissing(let kind, let nodeID, let property):
            let node = nodeID.map { "#\($0)" } ?? "(not yet saved)"
            return "node \(node) of kind \(kind) has no '\(property)' property, which its type is always "
                 + "created with, so the graph is damaged; `reset` rebuilds the graph"
        case .severalWiresOnOneWirePort(let port, let wires):
            let names = wires.map { "'\($0)'" }.joined(separator: ", ")
            return "input port '\(port)' takes one wire, and \(wires.count) are wired to it: \(names). "
                 + "Wire it once; settings from two places meet in a ConfigMerger, whose base and override say which wins"
        case .inputValueInError:
            return "an input is in error"
        case .inputValuePending:
            return "an input has no value yet"
        case .inputValueNotProduced:
            return "an input has never been produced"
        case .processNotSupported:
            return "this node cannot be processed"
        case .cannotHaveProperties:
            return "this node takes no properties"
        case .cannotDeleteNodeWithOutputs:
            return "a node whose outputs are still wired cannot be deleted"
        case .graphSpecBadIntegrity(let currentShapeNode, let expectedShapeNode, let log):
            return "the graph does not match its spec: it holds \(currentShapeNode) where " +
                   "\(expectedShapeNode) is expected\n\(log)"
        case .nameCollision(let path, let existingKind):
            return "'\(path)' is already taken by a node of kind \(existingKind), and two " +
                   "children of one folder may not share a name"
        case .sourceCannotProcess(let type):
            return "\(type) declares no input ports and cannot process"
        case .noSuchFolder(let path):
            return "no such folder: \(path)"
        case .unexpectedNodeKind(let kind):
            return "a node of kind \(kind) is not one this listing knows"
        case .folderNotDeletable(let path):
            return "\(path.map { "the folder \($0)" } ?? "a folder") cannot be deleted: something below it is not deletable"
        case .notAFolder(let kind):
            return "a node of kind \(kind) is not a folder, and folders are made only below a folder"
        case .nodeHasNoName(let nodeID):
            return "node \(nodeID.map { "#\($0)" } ?? "(not yet saved)") has no name, so no path can be built through it"
        }
    }
}
