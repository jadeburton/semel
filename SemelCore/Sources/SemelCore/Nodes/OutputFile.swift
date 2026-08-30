//
//  OutputFile.swift
//  build_system
//
//  Created by Jade Burton on 28.06.26.
//

import SemelNodeKit

protocol HasPath {
    var path: Path { get }
}

extension HasPath {
    var name: String {
        path.lastComponent ?? ""
    }

    /// The parent path (everything except the last component), or `.empty` if at root.
    var containingPath: Path {
        path.deletingLastComponent ?? .empty
    }

    func resolveFolderID(path: Path) throws -> ObjectID? {
        guard !path.isEmpty else {
            // Empty path → root folder, which has no parent ID.
            return nil
        }

        guard let rootName = path.firstComponent else {
            throw NodeError.other(message: "Path '\(path)' has no components")
        }

        let rootNode: NodeRecord
        switch rootName {
        case Folder.inputFileSystemName:
            rootNode = try Folder.inputFileSystem
        case Folder.outputFileSystemName:
            rootNode = try Folder.outputFileSystem
        default:
            throw NodeError.other(message: "Path '\(path)' must begin with 'input:' or 'output:', got '\(rootName)'")
        }

        // If the path is just the root (e.g. Path(Folder.inputFileSystemName)), return the root ID.
        guard let subPath = path.deletingFirstComponent else {
            return (try rootNode.requireID())
        }

        let resolvedFolder = try rootNode.ensureEntirePathExistsAsFolders(subPath, pinned: false)
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
        thisNode.name = name
        if thisNode.parentNodeID == nil {
            thisNode.parentNodeID = try resolveFolderID(path: containingPath)
        }
    }
}

// OutputFile is held alive by a ProjectBuilder, which receives a Wire from its `status` output.
struct OutputFile: Node, FileType, HasPath, Pinnable, FileMetadataProvider {

    public static let kind: UInt = 8

    static let inputPort = "input"
    static let fileMetadataInputPort = FileMetadata.portName
    static let statusOutputPort = "status"

    public var thisNode: NodeRecord

    var path: Path {
        Path(thisNode.properties["path"]!)
    }

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
        assert(!path.string.contains(Folder.inputFileSystemName))
        try placeInFileSystem()
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [.required(inputPort), .optional(fileMetadataInputPort)],
        outputPorts: [statusOutputPort]
    )

    public func didCreate() throws -> ProcessOutput? {
        return .init(outputValues: [Self.statusOutputPort: .noValue(reason: .error(messageDataObjectHash: try "Missing".intern()))],
                     inputWireExpectations: [:])
    }

    var isPinned: Bool {
        get throws {
            guard let nodeValue = try read() else {
                return false
            }

            return !nodeValue.isNoValue
        }
    }

    public func process(input: ProcessInput) throws -> ProcessOutput {
        func describeValue(_ value: NodeValue) -> String {
            switch value {
            case .noValue(let reason):
                switch reason {
                case .pending:
                    return "Updating.."
                case .error:
                    return "Error"
                }
            case .value:
                return "OK"
            }
        }

        let inputValue = input.inputValues[Self.inputPort]!.first!.value
        let previousStatus = try thisNode.readFromOutputPort(Self.statusOutputPort)

        let oldDescription = describeValue(previousStatus)
        let newDescription = describeValue(inputValue)

        let outputValue: NodeValue

        switch inputValue {

        case .noValue(let reason):
            outputValue = .noValue(reason: reason)

        case .value:
            outputValue = .value(try "Product is up to date".intern())

        }

        if newDescription != oldDescription {
            print("\(path): \(newDescription)")
        }

        return .init(outputValues: [Self.statusOutputPort: outputValue], inputWireExpectations: [:])
    }

    func read() throws -> NodeValue? {
        try thisNode.readFromInputPort(Self.inputPort).first?.value
    }

    func readFileMetadata() throws -> FileMetadata? {
        guard let metadataValue = try thisNode.readFromInputPort(Self.fileMetadataInputPort).first?.value,
              case .value(let hash) = metadataValue,
              let json = try? hash.resolveAsString()
        else { return nil }
        return FileMetadata.decode(from: json)
    }
}
