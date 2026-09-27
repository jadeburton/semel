// NodeError.swift
// SemelNodeKit
//
// The errors a node can throw. Part of the node-authoring API rather than the
// engine: a node reports these, and the engine decides what to do about them.
//
// Each case carries its own sentence, because the engine interns a thrown error's text
// straight onto the failing node's output ports and the user reads it there. Without one,
// a reader is handed the enum's debug form — `other(message: "…\n…")`, one line, quoted,
// with every newline escaped — instead of the words the node wrote.

import SemelDatabaseModels

public enum NodeError: Error, CustomStringConvertible {
    case nodeNotFound
    /// A node holding no row for an output port its type declares. Every node is given one
    /// per declared port when it is created, so this is a graph something damaged — not a
    /// port that has yet to be written, which holds a state of its own.
    case outputPortMissing(nodeID: ObjectID, port: String)
    /// More than one wire on an input port that takes one, by the port and the wires'
    /// names. The settings nodes' ports are the ones that say so: two sets of settings meet
    /// only in a `ConfigMerger`, whose `base` and `override` state which wins, and a port
    /// that folded its wires together in key order would be a second merge with no stated
    /// precedence (B-120).
    case severalWiresOnOneWirePort(port: String, wires: [String])
    /// Thrown by `expectValue()` when the value asked for is not there to be had. These
    /// three are control flow rather than messages: the engine turns each into the
    /// `NoValueReason` the node publishes, before anything is written to a port, so a node
    /// stopped by one of them says so by its state.
    case inputValueInError
    case inputValuePending
    /// Thrown when an input has never had a value and nothing has failed to make one.
    case inputValueNotProduced
    case other(message: String)
    case processNotSupported
    case cannotHaveProperties
    case cannotDeleteNodeWithOutputs
    case graphSpecBadIntegrity(currentShapeNode: String, expectedShapeNode: String, log: String)
    /// Two children of one folder may never share a name. The tree is walked by name, so
    /// a duplicate makes every path through that folder ambiguous — `childNode` would
    /// take whichever the database returned first.
    case nameCollision(path: String, existingKind: UInt)

    /// The state the engine writes to every output port of a node this error stopped, or
    /// nil when the error is the node's own and reaches the port as its message.
    ///
    /// Spelled out case by case rather than with a `default`, so that a case added here with
    /// a state behind it has to say which one, instead of being published as an error
    /// carrying its own description.
    public var publishedState: NoValueReason? {
        switch self {
        case .inputValuePending:     return .pending
        case .inputValueNotProduced: return .inputNotProduced
        case .inputValueInError:     return .inputInError

        case .nodeNotFound,
             .outputPortMissing,
             .severalWiresOnOneWirePort,
             .other,
             .processNotSupported,
             .cannotHaveProperties,
             .cannotDeleteNodeWithOutputs,
             .graphSpecBadIntegrity,
             .nameCollision:
            return nil
        }
    }

    public var description: String {
        switch self {
        case .nodeNotFound:
            return "there is no such node"
        case .outputPortMissing(let nodeID, let port):
            return "node #\(nodeID) holds no row for its output port '\(port)', which its type declares, so the "
                 + "graph is damaged; `check` names every such port and `reset` rebuilds the graph"
        case .severalWiresOnOneWirePort(let port, let wires):
            let names = wires.map { "'\($0)'" }.joined(separator: ", ")
            return "input port '\(port)' takes one wire, and \(wires.count) are wired to it: \(names). "
                 + "Settings from two places meet in a ConfigMerger, whose base and override say which wins"
        case .inputValueInError:
            return "an input is in error"
        case .inputValuePending:
            return "an input has no value yet"
        case .inputValueNotProduced:
            return "an input has never been produced"
        case .other(let message):
            return message
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
        }
    }
}
