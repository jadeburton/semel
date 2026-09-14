//
//  TreeFile.swift
//  SemelCore
//

import SemelNodeKit

/// One file of a tree, as a value of its own.
///
/// A tree port carries N files in one manifest; everything else in the graph — an
/// `OutputFile`, a tool's input wire — carries one. This is the bridge: it names an entry
/// and puts that entry's content on `output` and its mode on `fileMetadata`, so a tree's
/// files can be published and consumed by nodes that know nothing about trees.
/// `ProjectBuilder` makes one per entry when it expands a tree product.
struct TreeFile: Node, FileMetadataProvider {

    public static let kind: UInt = 28

    /// The entry's path within the tree: `en.lproj/Localizable.strings`.
    static let nameProperty = "name"
    static let treeInputPort = "tree"
    static let outputPort = "output"
    static let fileMetadataOutputPort = FileMetadata.portName

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [.required(treeInputPort)],
        outputPorts: [outputPort, fileMetadataOutputPort]
    )

    public func process(input: ProcessInput) throws -> ProcessOutput {
        let name = thisNode.properties[Self.nameProperty] ?? ""

        guard let treeValue = input.inputValues[Self.treeInputPort]?.first?.value else {
            throw NodeError.other(message: "TreeFile '\(name)': nothing is wired to its tree port")
        }
        let manifest: TreeManifest
        switch treeValue {
        case .noValue(let reason):
            // Whatever stopped the tree stops every file of it, with the same reason.
            return .init(outputValues: [Self.outputPort: .noValue(reason: reason),
                                        Self.fileMetadataOutputPort: .noValue(reason: reason)],
                         inputWireSpecs: [:])
        case .value(let hash):
            manifest = try TypeRegistry.decodeAndCast(encodedJSON: try hash.resolveAsString())
        }

        guard let entry = manifest.entry(at: name) else {
            let message = "no file '\(name)' in the tree; it holds: " + manifest.entries.map(\.path).joined(separator: ", ")
            let reason = NoValueReason.error(messageDataObjectHash: try message.intern())
            return .init(outputValues: [Self.outputPort: .noValue(reason: reason),
                                        Self.fileMetadataOutputPort: .noValue(reason: reason)],
                         inputWireSpecs: [:])
        }

        let metadataJSON = try FileMetadata(mode: entry.mode).jsonString()
        return .init(outputValues: [Self.outputPort: .value(entry.hash),
                                    Self.fileMetadataOutputPort: .value(try metadataJSON.intern())],
                     inputWireSpecs: [:])
    }

    func readFileMetadata() throws -> FileMetadata? {
        guard case .value(let hash) = try thisNode.readFromOutputPort(Self.fileMetadataOutputPort) else {
            return nil
        }
        return FileMetadata.decode(from: try hash.resolveAsString())
    }
}
