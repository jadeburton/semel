// NodeFunction.swift
// SemelNodeKit
//
// What a node function is: the ports it declares, what `process` receives and returns, and
// the lifecycle callbacks the engine will make. Everything here is declaration — the
// engine's implementation of it, which reads and writes the graph, stays in the engine.

import Foundation
import SemelDatabaseModels

// A node in the graph. A Node is the raw, database-level entity; this wraps it and adds
// behaviour.
//
// One protocol, whether or not the node has inputs. A node declaring no input ports — a
// StaticFile, a Folder — is a source: the graph neither schedules nor processes it, because
// there would be nothing to hand it. `descriptor.hasInputs` is what says which it is.
public protocol NodeFunction: WithKind, WithChildren {
    var thisNode: Node { get set }

    init(thisNode: Node) throws

    func didCreate() throws -> ProcessOutput?

    static var descriptor: NodeFunctionDescriptor { get }

    /// A Node can be immediately deleted as soon as all of its output wires are deleted AND if this method returns true.
    func canBeDeleted() throws -> Bool

    /// Called only when `descriptor.hasInputs`.
    ///
    /// A source node has to declare this anyway, and deliberately gets no default: a default
    /// would also cover a node function that *does* take inputs and forgot to implement it,
    /// turning a compile error into a surprise at run time.
    func process(input: ProcessInput) throws -> ProcessOutput
}

public struct ProcessInput {
    public let inputValues: [String: [String: NodeValue]]

    public init(inputValues: [String: [String: NodeValue]]) {
        self.inputValues = inputValues
    }
}

public struct ProcessOutput {
    public let outputValues: [String: NodeValue]
    /// Each named dynamic input port has N named wires connected to it, each with an expectation
    public let inputWireExpectations: [String: [String: String]]

    public init(outputValues: [String: NodeValue],
                inputWireExpectations: [String: [String: String]]) {
        self.outputValues = outputValues
        self.inputWireExpectations = inputWireExpectations
    }
}

public protocol WithDefaultInitializer {
    init() throws
}

extension NodeFunction {
    /// The node's id, or an integrity error if it has not been persisted yet.
    public func requireID() throws -> ObjectID {
        try thisNode.requireID()
    }

    public var parentNodeID: ObjectID? {
        thisNode.parentNodeID
    }

    public var scheduled: Bool {
        thisNode.scheduled
    }

    public var searchKey: String? {
        thisNode.searchKey
    }
}

public protocol WithChildren {
    func onChildAdded(nodeID: ObjectID) throws
    func onChildContentChanged(nodeID: ObjectID, name: String) throws
    func onChildDeleted(nodeID: ObjectID) throws
}

extension NodeFunction {
    public var descriptor: NodeFunctionDescriptor { Self.descriptor }
}

public extension NodeFunction {

    /// Most nodes have nothing to publish at creation.
    func didCreate() throws -> ProcessOutput? {
        nil
    }

    /// Most nodes may be collected as soon as nothing consumes them. The file-system types
    /// override this: a pushed file outlives its consumers, and a folder with children is
    /// not empty.
    func canBeDeleted() throws -> Bool {
        true
    }
}

public extension WithChildren {
    func onChildAdded(nodeID: ObjectID) throws {
    }

    func onChildDeleted(nodeID: ObjectID) throws {
    }

    func onChildContentChanged(nodeID: ObjectID, name: String) throws {
    }
}
