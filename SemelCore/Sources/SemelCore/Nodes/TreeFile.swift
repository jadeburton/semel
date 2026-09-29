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
///
/// A symbolic link entry is put on the ports as a pushed link is: its target on
/// `fileMetadata`, which is what a product and the export read, and on `output` what it
/// names in the tree — a file's bytes, or the empty file for a folder — for whatever reads
/// the entry's bytes.
struct TreeFile: Node, FileMetadataProvider {

    public static let kind: UInt = 28

    /// 2: a link entry is a link, where every entry was a file (B-77).
    public static let implementationVersion = 2

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
        // Whatever stopped the tree stops every file of it: demanding the value hands the
        // engine what stood in the way, and it writes the state that follows onto both ports.
        let manifest: TreeManifest = try TypeRegistry.decodeAndCast(
            encodedJSON: try treeValue.expectValue().resolveAsString())

        guard let entry = manifest.entry(at: name) else {
            let message = "no file '\(name)' in the tree; it holds: " + manifest.entries.map(\.path).joined(separator: ", ")
            let reason = NoValueReason.error(messageDataObjectHash: try message.intern())
            return .init(outputValues: [Self.outputPort: .noValue(reason: reason),
                                        Self.fileMetadataOutputPort: .noValue(reason: reason)],
                         inputWireSpecs: [:])
        }

        let content: DataObjectHash
        let metadata: FileMetadata
        switch entry.content {
        case .file(let hash, let mode):
            content  = hash
            metadata = FileMetadata(mode: mode)
        case .symbolicLink(let target):
            guard case .file(let named)? = manifest.resolve(entry.path),
                  case .file(let hash, let mode) = named.content else {
                content  = try [UInt8]().intern()
                metadata = FileMetadata(symbolicLinkTarget: target)
                break
            }
            content  = hash
            metadata = FileMetadata(mode: mode, symbolicLinkTarget: target)
        }
        return .init(outputValues: [Self.outputPort: .value(content),
                                    Self.fileMetadataOutputPort: .value(try metadata.jsonString().intern())],
                     inputWireSpecs: [:])
    }

    func readFileMetadata() throws -> FileMetadata? {
        guard case .value(let hash) = try thisNode.readFromOutputPort(Self.fileMetadataOutputPort) else {
            return nil
        }
        return FileMetadata.decode(from: try hash.resolveAsString())
    }
}
