//
//  FormulaPrelude.swift
//  SemelCore
//
//  The text a plugin provides for an include name (B-108), on a wire. A formula that says
//  `include 'clang'` has its builder wire `FormulaPrelude(name: 'clang').formula`, the same
//  way it wires a converter's `.formula` — so the text is in the builder's cache key, and a
//  prelude that changes wakes exactly the builders that include it.

import SemelDatabaseModels
import SemelNodeKit

/// A source filled by the runtime rather than by a wire: the answer the registered
/// `FormulaIncludeProviders` give for `name`, asked when the node is created and again at
/// every start, and written only where it differs from what the port holds.
///
/// What it publishes is formula text beginning with the prelude's `namespace` line, so the
/// parser can put the funcs under it; a name nobody answers, a refusal or a conflict is an
/// error on the port carrying the sentence the user reads.
public struct FormulaPrelude: Node {
    public static let kind: UInt = 37

    static let formulaOutputPort = "formula"
    static let nameProperty      = "name"

    public static let descriptor = NodeDescriptor(inputPorts: [], outputPorts: [formulaOutputPort])

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    var name: String {
        thisNode.properties[Self.nameProperty] ?? ""
    }

    /// The spec a builder wires for `include '<name>'`.
    static func spec(forIncludeNamed name: String) -> GraphSpecNode {
        GraphSpecNode(typeName: "\(Self.self)",
                      properties: [GraphSpecProperty(key: nameProperty, value: name)],
                      outputPort: formulaOutputPort)
    }

    /// The formula text a prelude is published as: its namespace, then its funcs.
    static func publishedText(namespace: String, text: String) -> String {
        "namespace \(namespace)\n\(text)"
    }

    public func didCreate() throws -> ProcessOutput? {
        ProcessOutput(outputValues: [Self.formulaOutputPort: try answer()], inputWireSpecs: [:])
    }

    /// What the providers say about this node's name, as the value its port publishes.
    func answer() throws -> NodeValue {
        switch FormulaIncludeProviders.resolve(includeNamed: name) {
        case .prelude(let namespace, let text):
            return .value(try Self.publishedText(namespace: namespace, text: text).intern())
        case .failed(let message):
            return .noValue(reason: .error(messageDataObjectHash: try message.intern()))
        }
    }

    /// Asks the providers again for every resident prelude and writes the answers that
    /// changed. Called at start: the providers are whatever this server links or loads, and
    /// a plugin replaced since the last start is a changed prelude for every formula that
    /// includes it.
    static func refreshAll(database: DatabaseLayer) throws {
        for nodeRecord in try database.node.select(kind: kind) {
            let prelude = try FormulaPrelude(thisNode: nodeRecord)
            try nodeRecord.writeToOutputPort(formulaOutputPort, value: try prelude.answer())
        }
    }

    /// Never reached in a working graph: a node declaring no input ports is not scheduled.
    public func process(input: ProcessInput) throws -> ProcessOutput {
        throw NodeError.other(message: "\(Self.self) declares no input ports and cannot process")
    }
}
