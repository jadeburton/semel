// Node.swift
// SemelNodeKit
//
// What a node is: the ports it declares, what `process` receives and returns, and
// the lifecycle callbacks the engine will make. Everything here is declaration — the
// engine's implementation of it, which reads and writes the graph, stays in the engine.

import Foundation
import SemelDatabaseModels

// A node in the graph. A NodeRecord is the raw, database-level entity; this wraps it and adds
// behaviour.
//
// One protocol, whether or not the node has inputs. A node declaring no input ports — a
// StaticFile, a Folder — is a source: the graph neither schedules nor processes it, because
// there would be nothing to hand it. `descriptor.hasInputs` is what says which it is.
public protocol Node: WithKind, WithChildren {
    var thisNode: NodeRecord { get set }

    init(thisNode: NodeRecord) throws

    func didCreate() throws -> ProcessOutput?

    static var descriptor: NodeDescriptor { get }

    /// A node can be immediately deleted as soon as all of its output wires are deleted AND if this method returns true.
    func canBeDeleted() throws -> Bool

    /// Called only when `descriptor.hasInputs`.
    ///
    /// A source node has to declare this anyway, and deliberately gets no default: a default
    /// would also cover a node that *does* take inputs and forgot to implement it,
    /// turning a compile error into a surprise at run time.
    func process(input: ProcessInput) throws -> ProcessOutput

    /// Anything the node's output depends on that is neither its type, its properties nor
    /// what arrives on its wires — and so would otherwise be missing from its cache key.
    ///
    /// The cache key must cover everything that can change a node's output (AGENTS.md).
    /// A tool that reads the machine — the Swift tools pass `-sdk` and compile against
    /// whatever is behind that path — contributes a fingerprint of what it read, so two
    /// machines with the same declared settings and different SDK contents do not share
    /// an entry. Most nodes read nothing outside their inputs and return nil. The input is
    /// passed because *which* outside thing a node reads can itself be configured — the
    /// Swift tools fingerprint whichever SDK their configuration names. Note what this
    /// cannot do: a key only stops a wrong reuse; a change here never causes a
    /// recomputation, because an unscheduled node never rebuilds its key.
    func cacheKeyMaterial(input: ProcessInput) throws -> String?

    /// Which implementation of this node type produced an output. Bump when this node's
    /// output for equal inputs changes; the cache key carries it, so an entry written by
    /// the implementation before the bump is a miss rather than a wrong hit.
    ///
    /// The bump is per node type on purpose. A version stamped on the engine as a whole
    /// would invalidate the entries of every type a release touched and every type it did
    /// not, which costs a cold build of everything in the home for a fix to one node.
    static var implementationVersion: Int { get }

    /// Properties that are part of a node's identity but not of its cache key: a value
    /// the key deliberately strips from elsewhere, which would otherwise return through
    /// the properties. `projectRoot` is the one every node has reason to exclude.
    static var cacheKeyExcludedProperties: Set<String> { get }
}

public struct ProcessInput {
    public let inputValues: [String: [String: NodeValue]]

    public init(inputValues: [String: [String: NodeValue]]) {
        self.inputValues = inputValues
    }
}

public struct ProcessOutput {
    public let outputValues: [String: NodeValue]
    /// Each named dynamic input port has N named wires connected to it, each with a spec
    public let inputWireSpecs: [String: [String: String]]

    public init(outputValues: [String: NodeValue],
                inputWireSpecs: [String: [String: String]]) {
        self.outputValues = outputValues
        self.inputWireSpecs = inputWireSpecs
    }
}

public protocol WithDefaultInitializer {
    init() throws
}

extension Node {
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

    public var identity: String? {
        thisNode.identity
    }
}

public protocol WithChildren {
    func onChildAdded(nodeID: ObjectID) throws
    func onChildContentChanged(nodeID: ObjectID, name: String) throws
    func onChildDeleted(nodeID: ObjectID) throws
}

extension Node {
    public var descriptor: NodeDescriptor { Self.descriptor }
}

public extension Node {

    /// Most nodes have nothing to publish at creation.
    func didCreate() throws -> ProcessOutput? {
        nil
    }

    /// Most nodes read nothing outside their inputs.
    func cacheKeyMaterial(input: ProcessInput) throws -> String? {
        nil
    }

    /// A node type is at its first implementation until what it emits for equal inputs
    /// changes, so the constant is declared only by a type that has changed.
    static var implementationVersion: Int { 1 }

    // The literal must agree with `Node.projectRootProperty` in SemelCore's Cache.swift,
    // which SemelNodeKit cannot see.
    static var cacheKeyExcludedProperties: Set<String> { ["projectRoot"] }

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
