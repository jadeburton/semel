//
//  StaticFile.swift
//  build_system
//
//  Created by Jade Burton on 22.02.26.
//

struct StaticFile: InputlessNodeFunction {
    static let kind: UInt = 3

    let containingPath: String
    let name: String

    enum CodingKeys: CodingKey {
        case containingPath
        case name
    }

    var initialName: String? {
        name
    }

    static let outputPort = "output"

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

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [], outputPorts: [outputPort])

    var initialParentNodeID: ObjectID? {
        get throws {
            // All StaticFiles reside beneath inputFileSystem
            try Node.inputFileSystem.ensureEntirePathExistsAsFolders(containingPath).id!
        }
    }

    func didCreate(node: Node) throws -> ProcessOutput {


        return .init(outputValues: [Self.outputPort: .noValue(reason:.error(message: "Missing"))],
                     inputWireExpectations: [:])
    }

    // If StaticFile has content set, it must not be deleted even when there are no output Wires. However, if
    // it has no content set (i.e. the user never pushed the file, or they deleted it) then it can be deleted
    // if there are no output Wires.
    func canBeDeleted(thisNode: Node) throws -> Bool {

        guard let nodeValue = try read(thisNode: thisNode) else {
            return true
        }

        return nodeValue.isNoValue
    }

    func read(thisNode: Node) throws -> NodeValue? {
        try thisNode.readFromOutputPort(Self.outputPort)
    }

    func replaceContent(thisNode: Node, _ content: DataObjectHash) throws -> Bool {
        try thisNode.writeToOutputPort(Self.outputPort, value: .value(content))
    }

    func eraseContents(thisNode: Node) throws -> Bool{
        try thisNode.writeToOutputPort(Self.outputPort, value: .noValue(reason: .error(message: "File deleted")))
    }
}

// OutputFile is held alive by a ProjectBuilder, which receives a Wire from its `status` output.
struct OutputFile: NodeFunction {

    static let kind: UInt = 8

    let properties: [String: String]

    enum CodingKeys: CodingKey {
        case properties
    }

    static let inputPort = "input"
    static let statusOutputPort = "status"

    init() {
        properties = [String: String]()
    }

    init(properties: [String : String] = [String: String]()) {
        self.properties = properties
    }

    var initialName: String? {
        properties["path"]?.lastPathComponent ?? "untitled"
    }

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [inputPort], outputPorts: [statusOutputPort])

    func didCreate(node: Node) throws -> ProcessOutput {
        // OutputFile needs to be listable as part of a folder hierarchy, so we maintain that.

        // ensure a chain of Folders exist above us, all the way to "outputFileSystem" root Folder.

        let path = properties["path"]!
        let pathWithoutLastComponent = path//.removingLastPathComponent // TODO!

        // /outputFileSystem/bin/mylib.dylib
        try Node.outputFileSystem.ensureEntirePathExistsAsFolders(pathWithoutLastComponent)

        return .init(outputValues: [Self.statusOutputPort: .noValue(reason: .pending)],
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
}
