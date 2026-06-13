//
//  OutputFile.swift
//  build_system
//
//  Created by Jade Burton on 28.06.26.
//

// OutputFile is held alive by a ProjectBuilder, which receives a Wire from its `status` output.
struct OutputFile: NodeFunction, FileType {

    static let kind: UInt = 8


    let containingPath: String
    let name: String

    enum CodingKeys: CodingKey {
        case containingPath
        case name
    }

    var initialName: String? {
        name
    }

    static let inputPort = "input"
    static let statusOutputPort = "status"

    var embeddedNode: Node?

    var properties: [String : String] {
        ["path": containingPath.appendingPathComponent(name)]
    }

    // When GraphShapeApplier needs to resolve "StaticFile(path: 'src/hello.c')", we receive properties with the path.
    // At that point we need to ensure the Folder hierarchy exists above us.
    init(properties: [String : String] = [String: String]()) {
        let path = properties["path"]!
        containingPath = path.deletingLastPathComponent() ?? ""
        name = path.lastPathComponent
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

        let path = properties["path"]!
        let pathWithoutLastComponent = path.deletingLastPathComponent() ?? "" // TODO!

        try outputFileSystem.ensureEntirePathExistsAsFolders(pathWithoutLastComponent)

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
