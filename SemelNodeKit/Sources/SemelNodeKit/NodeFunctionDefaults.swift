// NodeFunctionDefaults.swift
// SemelNodeKit
//
// What a node function gets for free.
//
// These stayed in the engine when the protocol moved, which compiled fine — the engine's
// own nodes could see them — and then made it impossible to conform from anywhere else: a
// default implementation is invisible across a module boundary, so every requirement it
// covered came back as "does not conform, add stubs". None of them touches the graph, so
// they belong with the declaration.

import SemelDatabaseModels

public extension InputlessNodeFunction {

    /// Most nodes have nothing to publish at creation.
    func didCreate() throws -> ProcessOutput? { nil }

    /// Most nodes may be collected as soon as nothing consumes them. The file-system types
    /// override this: a pushed file outlives its consumers, and a folder with children is
    /// not empty.
    func canBeDeleted() throws -> Bool { true }

    /// Only the folder types care about their children changing.
    func onChildAdded(nodeID: ObjectID) throws { }
    func onChildDeleted(nodeID: ObjectID) throws { }
    func onChildContentChanged(nodeID: ObjectID, name: String) throws { }

    func willBeDeleted() throws { }
    func didWriteOutputs(output: ProcessOutput) throws { }

    /// Every property distinguishes the node by default. A type that holds a property which
    /// must *not* affect its identity overrides this to leave it out.
    func graphShapeArgs(node: Node) -> [GraphShapeArg] {
        thisNode.properties
            .sorted(by: { $0.key < $1.key })
            .map { GraphShapeArg(key: $0.key, value: $0.value) }
    }
}
