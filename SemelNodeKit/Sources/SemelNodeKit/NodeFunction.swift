// NodeFunction.swift
// SemelNodeKit
//
// What a node function is: the ports it declares, what `process` receives and returns, and
// the lifecycle callbacks the engine will make. Everything here is declaration — the
// engine's implementation of it, which reads and writes the graph, stays in the engine.

import Foundation
import SemelDatabaseModels

import SemelNodeKit

// MARK: - Protocols


public struct ProcessInput {
    public let inputValues: [String: [String: NodeValue]]

    public init(inputValues: [String: [String: NodeValue]]) {
        self.inputValues = inputValues
    }
}

public struct ProcessOutput {
    public let outputValues: [String: NodeValue]
    public let inputWireExpectations: [String: [String: String]] // each dynamic input port has N wires connected to it, each wire has an expectation

    public init(outputValues: [String: NodeValue],
                inputWireExpectations: [String: [String: String]]) {
        self.outputValues = outputValues
        self.inputWireExpectations = inputWireExpectations
    }
}

public protocol WithDefaultInitializer {
    init() throws
}

extension InputlessNodeFunction {
    public var thisNode: Node {
        embeddedNode
    }

    public var id: ObjectID? {
        thisNode.id
    }

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

public protocol InputlessNodeFunction: WithKind {
    var embeddedNode: Node { get set }

    init(thisNode: Node) throws

    func didCreate() throws -> ProcessOutput?

    static var descriptor: NodeFunctionDescriptor { get }

    /// Returns the init-time key-value arguments that distinguish this node from
    /// others of the same type (e.g. `path='src/hello.c'` for StaticFile).
    /// Declared here so Swift dispatches it dynamically via the protocol witness table,
    /// not statically via the extension — which would always call the default `[]`.
    func graphShapeArgs(node: Node) -> [GraphShapeArg]

    // Most Nodes can be immediately deleted as soon as all of their output wires are deleted. Deleting involves deleting all input Wires,
    // which may cause a cascade deletion.
    // Some Nodes should not be deleted even if they have no connected output Wires;
    // - ProjectFinder (which is the root object, and has no outputs by design)
    // - StaticFile. If StaticFile has content set, it must not be deleted even when there are no output Wires. However, if
    //   it has no content set (i.e. the user never pushed the file, or they deleted it) then it can be deleted if there are no output Wires.
    // - If the Node (usually a Folder) has one or more children it must not be deleted. (If a Node is deleted, we must check if it's parent can be deleted.)
    func canBeDeleted() throws -> Bool

    func onChildAdded(nodeID: ObjectID) throws
    func onChildContentChanged(nodeID: ObjectID, name: String) throws
    func onChildDeleted(nodeID: ObjectID) throws

    /// Called immediately before the node is permanently removed from the DB.
    /// Default implementation is a no-op; override to perform cleanup or logging.
    func willBeDeleted() throws

    /// Called at the end of `writeToOutputs`, after all output port values have
    /// been written to the DB.  Default implementation is a no-op; override to
    /// react to the written output without mutating the Node itself.
    func didWriteOutputs(output: ProcessOutput) throws
}

extension InputlessNodeFunction {
    public var descriptor: NodeFunctionDescriptor { Self.descriptor }
}

public protocol NodeFunction: InputlessNodeFunction {
    /// Increment this to invalidate cached outputs when processing logic changes.
    /// Defaults to 0; override in any NodeFunction whose output format changes.
    static var codeVersion: Int { get }

    /// Anything read from the *machine* rather than from a wire or a property that can
    /// change this node's output — an SDK version, a resolved toolchain, an environment
    /// variable the tool consults.
    ///
    /// Such values are invisible to the ordinary key, which covers only the node type,
    /// its properties and its inputs. A node that omits one here produces identical keys
    /// for genuinely different builds, which is the single failure a cache must never
    /// have: locally that is a stale result you eventually notice, and on a shared cache
    /// it is a wrong build handed to everyone else that looks correct on the machine that
    /// produced it.
    ///
    /// Empty means "nothing beyond the graph influences my output", and leaves the key
    /// byte-for-byte as it was.
    var cacheKeyEnvironment: String { get }

    func process(input: ProcessInput) throws -> ProcessOutput
}

extension NodeFunction {
    public static var codeVersion: Int { 0 }
    public var cacheKeyEnvironment: String { "" }
}

