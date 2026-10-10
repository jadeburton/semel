//
//  OutputFile.swift
//  semel
//
//  Created by Jade Burton on 28.06.26.
//

import SemelNodeKit

/// A node standing at a path in the file-system tree: `Folder`, `StaticFile`, `OutputFile`.
protocol HasPath {
    /// The property every node of the type is created with, holding its path.
    static var pathProperty: String { get }
}

extension HasPath where Self: Node {
    /// The node's path, from the property its type is always created with. Throws for a
    /// row without one, which nothing makes — a damaged graph, reported against the node
    /// that reads it rather than crashing the server that does.
    var path: Path {
        get throws {
            guard let path = thisNode.properties[Self.pathProperty] else {
                throw NodeError.propertyMissing(kind: Self.kind, nodeID: thisNode.id, property: Self.pathProperty)
            }
            return Path(path)
        }
    }

    var name: String {
        get throws {
            try path.lastComponent ?? ""
        }
    }

    /// The parent path (everything except the last component), or `.empty` if at root.
    var containingPath: Path {
        get throws {
            try path.deletingLastComponent ?? .empty
        }
    }

    func resolveFolderID(path: Path) throws -> ObjectID? {
        guard !path.isEmpty else {
            // Empty path → root folder, which has no parent ID.
            return nil
        }

        guard let rootName = path.firstComponent else {
            throw ErrorCondition.productPathInvalid(path: path.string, root: nil)
        }

        let rootNode: NodeRecord
        switch rootName {
        case Folder.inputFileSystemName:
            rootNode = try Folder.inputFileSystem
        case Folder.outputFileSystemName:
            rootNode = try Folder.outputFileSystem
        default:
            throw ErrorCondition.productPathInvalid(path: path.string, root: rootName)
        }

        // If the path is just the root (e.g. Path(Folder.inputFileSystemName)), return the root ID.
        guard let subPath = path.deletingFirstComponent else {
            return (try rootNode.requireID())
        }

        let resolvedFolder = try rootNode.ensureEntirePathExistsAsFolders(subPath, pinned: false, forAChild: true)
        return (try resolvedFolder.requireID())
    }
}

extension HasPath where Self: Node {

    /// Puts this node in its place in the file-system tree: named after the last component
    /// of its path, parented to the folder that contains it.
    ///
    /// Every path-based node does exactly this on init. The rest of the vocabulary it needs
    /// — `name`, `containingPath`, `resolveFolderID` — was already here; only the step that
    /// uses them stayed behind, copied into `Folder`, `StaticFile` and `OutputFile` alike.
    ///
    /// The parent is resolved only when there is not one already. A node loaded from the
    /// database arrives with its parent set, and resolving again would walk a tree that
    /// exists to create folders that exist.
    mutating func placeInFileSystem() throws {
        thisNode.name = try name
        if thisNode.parentNodeID == nil {
            thisNode.parentNodeID = try resolveFolderID(path: containingPath)
        }
    }
}

// OutputFile is held alive by a ProjectBuilder, which receives a Wire from its `status` output.
struct OutputFile: Node, FileType, HasPath, Pinnable, FileMetadataProvider {

    public static let kind: UInt = 8

    /// 2: several wires on `input` are an error naming them, where the status of one was
    /// published (B-141).
    /// 3: a failure is published as an `ErrorDocument`, the typed value a client renders,
    /// where it was a sentence (B-145).
    public static let implementationVersion = 3

    static let inputPort = "input"
    static let fileMetadataInputPort = FileMetadata.portName
    static let statusOutputPort = "status"
    static let pathProperty = "path"

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
        let outputPath = try self.path
        assert(!outputPath.string.contains(Folder.inputFileSystemName))
        try placeInFileSystem()
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [.required(inputPort), .optional(fileMetadataInputPort)],
        outputPorts: [statusOutputPort],
        fileMetadataInputPorts: [inputPort: fileMetadataInputPort],
        // Checking that the product has a value costs less than a lookup; an entry per product
        // would take cache slots from the tools (B-147).
        cachesOutputs: false
    )

    /// An artifact is pinned by the port it reads its bytes from, which is its *input* — so
    /// what a listing says about a product is what the node that builds it says.
    var pinnedValue: NodeValue? {
        get throws {
            try read()
        }
    }

    /// A product has no state of its own: it is not pushed, not removed and never runs, so
    /// every state here is one it reads from its input.
    ///
    /// Which makes `deleted` a state a product cannot be in. A user who removes a source
    /// has not removed the artifact — and whether the removal reaches the product as its
    /// own `deleted` or as the `inputInError` a builder publishes on meeting one is a
    /// question of what stands between them, not of what happened. One user action reads as
    /// one word: a product the removal stopped is a product that failed to be made.
    var listedState: FileWildcardEntryState {
        get throws {
            let inputState = try pinnedValue.map(FileWildcardEntryState.init) ?? .notProduced
            switch inputState {
            case .deleted:
                return .failed
            case .present, .pending, .notProduced, .failed:
                return inputState
            }
        }
    }

    /// Publishes what its input carries, and says nothing about it.
    ///
    /// What the user is told about a product is the difference between two settles, which
    /// the engine works out from the artifact snapshot table (B-50). A status transition
    /// seen here is a step inside a build — `pending` on the way to the same bytes as
    /// before is the common one — and a functional system hides those.
    ///
    /// Demanding the value is how this node reports a product it cannot publish: the
    /// engine writes the state that follows from what stood in the way, rather than this
    /// node repeating the failure of another.
    /// A product's own failure belongs to the product.
    public func errorSubject(input: ProcessInput?) -> ErrorDocument.Subject? {
        thisNode.properties[Self.pathProperty].map { .product(path: $0) }
    }

    public func process(input: ProcessInput) throws -> ProcessOutput {
        _ = try input.onlyWire(onRequiredPort: Self.inputPort).value.expectValue()

        return .init(outputValues: [Self.statusOutputPort: .value(try "Product is up to date".intern())],
                     inputWireSpecs: [:])
    }

    func read() throws -> NodeValue? {
        try thisNode.readFromInputPort(Self.inputPort).first?.value
    }

    func readFileMetadata() throws -> FileMetadata? {
        guard let metadataValue = try thisNode.readFromInputPort(Self.fileMetadataInputPort).first?.value,
              case .value(let hash) = metadataValue,
              let json = try? hash.resolveAsString() else {

            return nil
        }

        return FileMetadata.decode(from: json)
    }
}
