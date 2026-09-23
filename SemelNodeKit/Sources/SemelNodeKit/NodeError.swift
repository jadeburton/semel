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

public enum NodeError: Error, CustomStringConvertible {
    case nodeNotFound
    case onlyOneWireShouldBeConnectedToInput
    case inputValueInError
    case inputValuePending
    case other(message: String)
    case processNotSupported
    case cannotHaveProperties
    case cannotDeleteNodeWithOutputs
    /// The placeholder every node carries between being created and first processing. Its
    /// text is `Self.initializingMessage`, which the engine matches to keep a graph full of
    /// fresh nodes from reading as a graph full of failures.
    case initializing
    case graphSpecBadIntegrity(currentShapeNode: String, expectedShapeNode: String, log: String)
    /// Two children of one folder may never share a name. The tree is walked by name, so
    /// a duplicate makes every path through that folder ambiguous — `childNode` would
    /// take whichever the database returned first.
    case nameCollision(path: String, existingKind: UInt)

    /// The text of `.initializing`, named so the engine's filter and this description are
    /// one string rather than two that must agree.
    public static let initializingMessage = "initializing"

    public var description: String {
        switch self {
        case .nodeNotFound:
            return "there is no such node"
        case .onlyOneWireShouldBeConnectedToInput:
            return "an input port takes one wire, and more than one is connected"
        case .inputValueInError:
            return "an input is in error"
        case .inputValuePending:
            return "an input has no value yet"
        case .other(let message):
            return message
        case .processNotSupported:
            return "this node cannot be processed"
        case .cannotHaveProperties:
            return "this node takes no properties"
        case .cannotDeleteNodeWithOutputs:
            return "a node whose outputs are still wired cannot be deleted"
        case .initializing:
            return Self.initializingMessage
        case .graphSpecBadIntegrity(let currentShapeNode, let expectedShapeNode, let log):
            return "the graph does not match its spec: it holds \(currentShapeNode) where " +
                   "\(expectedShapeNode) is expected\n\(log)"
        case .nameCollision(let path, let existingKind):
            return "'\(path)' is already taken by a node of kind \(existingKind), and two " +
                   "children of one folder may not share a name"
        }
    }
}
