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
        embeddedNode!.name = name
        embeddedNode!.parentNodeID = try outputFileSystem.ensureEntirePathExistsAsFolders(containingPath).id!
    }

    var outputFileSystem: Node {
        get throws {
            try BuildEngine.shared.outputFileSystem
        }
    }

    var initialParentNodeID: ObjectID? {
        get throws {
            // All OutputFiles reside beneath outputFileSystem
            try outputFileSystem.ensureEntirePathExistsAsFolders(containingPath).id!
        }
    }

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [inputPort], outputPorts: [statusOutputPort])

    func didCreate() throws -> ProcessOutput? {
        // OutputFile needs to be listable as part of a folder hierarchy, so we maintain that.

        // ensure a chain of Folders exist above us, all the way to "outputFileSystem" root Folder.

        try outputFileSystem.ensureEntirePathExistsAsFolders(containingPath)

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
