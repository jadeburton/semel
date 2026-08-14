//
//  OutputFile.swift
//  build_system
//
//  Created by Jade Burton on 28.06.26.
//

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

        let rootNode: Node
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

// OutputFile is held alive by a ProjectBuilder, which receives a Wire from its `status` output.
struct OutputFile: NodeFunction, FileType, HasPath, Pinnable, FileMetadataProvider {

    static let kind: UInt = 8

    static let inputPort = "input"
    static let fileMetadataInputPort = FileMetadata.portName
    static let statusOutputPort = "status"

    var embeddedNode: Node

    var path: Path {
        Path(thisNode.properties["path"]!)
    }

    init(thisNode: Node) throws {
        embeddedNode = thisNode
        assert(!path.string.contains(Folder.inputFileSystemName))
        embeddedNode.name = name
        if embeddedNode.parentNodeID == nil {
            embeddedNode.parentNodeID = try resolveFolderID(path: containingPath)
        }
    }

    static let descriptor = NodeFunctionDescriptor(
        inputPorts: [.required(inputPort), .optional(fileMetadataInputPort)],
        outputPorts: [statusOutputPort]
    )

    func didCreate() throws -> ProcessOutput? {
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

    func process(input: ProcessInput) throws -> ProcessOutput {
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

    func didWriteOutputs(output: ProcessOutput) throws {
    }

    func willBeDeleted() throws {
        print("\(path): Deleted")
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
