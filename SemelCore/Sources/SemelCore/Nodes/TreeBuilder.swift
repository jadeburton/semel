//
//  TreeBuilder.swift
//  SemelCore
//

import SemelNodeKit

/// N files as one tree, each entry named by its wire's key and carrying its mode.
///
/// The counterpart of `TreeFile`: that takes one file out of a tree, this puts files into
/// one. A package's converter uses it to hand every module and every object behind a
/// product to a formula that only knows the product's name; the entries are values
/// nodes already produce, so nothing is copied, only named. An app bundle is one too
/// (`apple.bundle`), which is why the mode travels: an executable in the tree stays one.
struct TreeBuilder: Node {

    public static let kind: UInt = 33

    /// 2: a file pushed as a symbolic link is a link entry where its target is in the tree
    /// (B-77).
    /// 3: a failure is published as an `ErrorDocument`, the typed value a client renders,
    /// where it was a sentence (B-145).
    public static let implementationVersion = 3

    /// The files, one wire each; the wire's key is the entry's path in the tree.
    static let inputPort = "input"
    /// The modes of the files, one wire per file whose source publishes one, under the
    /// same key — and a link's target. Filled where the spec is built, never in a formula
    /// (`GraphSpecNode.wiringFileMetadata()`); a file with no wire here is written with the
    /// default mode.
    static let fileMetadataInputPort = FileMetadata.portName
    static let outputPort = "files"

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [.optional(inputPort, .many), .optional(fileMetadataInputPort, .many)],
        outputPorts: [outputPort],
        fileMetadataInputPorts: [inputPort: fileMetadataInputPort],
        // Placing hashes in a manifest costs what a lookup and a write cost (B-147).
        cachesOutputs: false
    )

    public func process(input: ProcessInput) throws -> ProcessOutput {
        let metadata = input.inputValues[Self.fileMetadataInputPort] ?? [:]
        var files: [TreeManifest.PlacedFile] = []
        for (key, value) in (input.inputValues[Self.inputPort] ?? [:]).sorted(by: { $0.key < $1.key }) {
            // Whatever stopped one file stops the tree: demanding the value hands the engine
            // what stood in the way, and it writes the state that follows.
            files.append(.init(path: key, hash: try value.expectValue(), metadata: FileMetadata.metadata(of: metadata[key])))
        }
        let tree = TreeManifest(placing: files)
        return .init(outputValues: [Self.outputPort: .value(try tree.toJSON().intern())], inputWireSpecs: [:])
    }
}
