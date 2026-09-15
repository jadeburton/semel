//
//  TreeBuilder.swift
//  SemelCore
//

import SemelNodeKit

/// N files as one tree, each entry named by its wire's key.
///
/// The counterpart of `TreeFile`: that takes one file out of a tree, this puts files into
/// one. A package's converter uses it to hand every module and every object behind a
/// product to a formula that only knows the product's name; the entries are values
/// nodes already produce, so nothing is copied, only named.
struct TreeBuilder: Node {

    public static let kind: UInt = 33

    /// The files, one wire each; the wire's key is the entry's path in the tree.
    static let inputPort = "input"
    static let outputPort = "files"

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [.optional(inputPort)],
        outputPorts: [outputPort]
    )

    public func process(input: ProcessInput) throws -> ProcessOutput {
        var entries: [TreeManifestEntry] = []
        for (key, value) in (input.inputValues[Self.inputPort] ?? [:]).sorted(by: { $0.key < $1.key }) {
            switch value {
            case .noValue(let reason):
                // Whatever stopped one file stops the tree, with the same reason.
                return .init(outputValues: [Self.outputPort: .noValue(reason: reason)], inputWireSpecs: [:])
            case .value(let hash):
                entries.append(TreeManifestEntry(path: key, hash: hash, mode: FileMetadata.defaultMode))
            }
        }
        let tree = TreeManifest(entries: entries)
        return .init(outputValues: [Self.outputPort: .value(try tree.toJSON().intern())], inputWireSpecs: [:])
    }
}
