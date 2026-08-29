// NodeError.swift
// SemelNodeKit
//
// The errors a node function can throw. Part of the node-authoring API rather than the
// engine: a node reports these, and the engine decides what to do about them.

public enum NodeError: Error {
    case nodeNotFound
    case onlyOneWireShouldBeConnectedToInput
    case inputValueInError
    case inputValuePending
    case other(message: String)
    case processNotSupported
    case cannotHaveProperties
    case cannotDeleteNodeWithOutputs
    case initializing
    case searchKeyBadIntegrity(currentShapeNode: String, expectedShapeNode: String, log: String)
    /// Two children of one folder may never share a name. The tree is walked by name, so
    /// a duplicate makes every path through that folder ambiguous — `childNode` would
    /// take whichever the database returned first.
    case nameCollision(path: String, existingKind: UInt)

}
