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
        case "inputFileSystem":
            rootNode = try BuildEngine.shared.inputFileSystem
        case "outputFileSystem":
            rootNode = try BuildEngine.shared.outputFileSystem
        default:
            throw NodeError.other(message: "Path '\(path)' must begin with 'inputFileSystem' or 'outputFileSystem', got '\(rootName)'")
        }

        // If the path is just the root (e.g. Path("inputFileSystem")), return the root ID.
        guard let subPath = path.deletingFirstComponent else {
            return rootNode.id!
        }

        let resolvedFolder = try rootNode.ensureEntirePathExistsAsFolders(subPath, pinned: false)
        return resolvedFolder.id!
    }
}

// OutputFile is held alive by a ProjectBuilder, which receives a Wire from its `status` output.
struct OutputFile: NodeFunction, FileType, HasPath, Pinnable {

    static let kind: UInt = 8

    static let inputPort = "input"
    static let statusOutputPort = "status"

    var embeddedNode: Node?

    var path: Path {
        Path(thisNode.properties["path"]!)
    }

    init(thisNode: Node) throws {
        embeddedNode = thisNode
        assert(!path.string.contains("inputFileSystem"))
        embeddedNode!.name = name
        embeddedNode!.parentNodeID = try resolveFolderID(path: containingPath)
    }

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [inputPort], outputPorts: [statusOutputPort])

    func didCreate() throws -> ProcessOutput? {
        return .init(outputValues: [Self.statusOutputPort: .noValue(reason: .error(message: "Missing"))],
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
        let inputValue = input.inputValues[Self.inputPort]!.first!

        let outputValue: NodeValue

        switch inputValue.value {

        case .noValue(let reason):
            outputValue = .noValue(reason: reason)

        case .value:
            outputValue = .value("Product is up to date".intern())

        }

        return .init(outputValues: [Self.statusOutputPort: outputValue], inputWireExpectations: [:])
    }

    func read() throws -> NodeValue? {
        try thisNode.readFromInputPort(Self.inputPort).first?.value
    }
}
