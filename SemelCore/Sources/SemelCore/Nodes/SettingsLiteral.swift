// SettingsLiteral.swift
// SemelCore
//
// Some settings written into a formula: `SettingsLiteral(moduleName: 'App')` publishes its
// properties as configuration text, the shape a config file's content has — the literal
// counterpart of a `StaticFile`, the way a string literal is of a string read from a file.

import SemelNodeKit

/// A source: no input ports, and its value is its properties.
///
/// It lays itself over nothing. Where a formula wants its literals over a config file's
/// settings — every prelude's per-module facts, the converters' `moduleName` and `linkage` —
/// it says so with a `ConfigMerger` whose `override` is this node, which is where the one
/// rule for two sets of settings meeting is stated (B-120). A literal that merged whatever
/// arrived on a port of its own was a second merge, with weaker rules, beside that one.
///
/// Published when the node is created and never again, because nothing it depends on can
/// change: the properties are its identity, so different literals are a different node.
/// With no static input port it carries no `projectRoot` either, so one set of literals is
/// one node however many projects write it.
public struct SettingsLiteral: Node {
    public static let kind: UInt = 9

    static let outputPort = "output"

    public static let descriptor = NodeDescriptor(inputPorts: [], outputPorts: [outputPort])

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public func didCreate() throws -> ProcessOutput? {
        ProcessOutput(outputValues: [Self.outputPort: .value(try thisNode.properties.asPlainText().intern())],
                      inputWireSpecs: [:])
    }

    /// Never reached in a working graph: a node declaring no input ports is not scheduled.
    public func process(input: ProcessInput) throws -> ProcessOutput {
        throw NodeError.sourceCannotProcess(type: "\(Self.self)")
    }
}
