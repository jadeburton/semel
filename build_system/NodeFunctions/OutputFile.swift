//
//  OutputFile.swift
//  build_system
//
//  Created by Jade Burton on 28.06.26.
//

protocol HasPath {
    var path: String { get }
}

extension HasPath {
    var name: String {
        path.lastPathComponent
    }

    var containingPath: String {
        path.deletingLastPathComponent() ?? ""
    }

    func resolveFolderID(path: String) throws -> ObjectID? {
        guard !path.isEmpty else {
            // "" -> nil because it is the root folder, which has no parent.
            return nil
        }

        let components = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        // The first component must be "inputFileSystem" or "outputFileSystem"
        guard let rootName = components.first else {
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

        // If the path is just the root (e.g. "inputFileSystem"), return the root folder's ID
        let subPath = components.dropFirst().joined(separator: "/")
        guard !subPath.isEmpty else {
            return rootNode.id!
        }

        // Walk (creating as needed) the remaining components beneath the root folder
        let resolvedFolder = try rootNode.ensureEntirePathExistsAsFolders(subPath)
        return resolvedFolder.id!
    }

}

// OutputFile is held alive by a ProjectBuilder, which receives a Wire from its `status` output.
struct OutputFile: NodeFunction, FileType, HasPath {

    static let kind: UInt = 8

    static let inputPort = "input"
    static let statusOutputPort = "status"

    var embeddedNode: Node?

    var path: String {
        thisNode.properties["path"]!
    }

    init(thisNode: Node) throws {
        embeddedNode = thisNode
        assert(!path.contains("inputFileSystem"))
        embeddedNode!.name = name
//        embeddedNode!.parentNodeID = try outputFileSystem.ensureEntirePathExistsAsFolders(containingPath).id!
        embeddedNode!.parentNodeID = try resolveFolderID(path: containingPath)
    }

//    var outputFileSystem: Node {
//        get throws {
//            try BuildEngine.shared.outputFileSystem
//        }
//    }

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [inputPort], outputPorts: [statusOutputPort])

    func didCreate() throws -> ProcessOutput? {
        // OutputFile needs to be listable as part of a folder hierarchy, so we maintain that.

        // ensure a chain of Folders exist above us, all the way to "outputFileSystem" root Folder.

      //  try outputFileSystem.ensureEntirePathExistsAsFolders(containingPath)

        return .init(outputValues: [Self.statusOutputPort: .noValue(reason: .error(message: "Missing"))],
                     inputWireExpectations: [:])
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
        let inputs = try thisNode.readFromInputPort(Self.inputPort)
        return inputs.first!.value
    }
}
