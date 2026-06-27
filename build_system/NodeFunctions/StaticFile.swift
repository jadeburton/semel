//
//  StaticFile.swift
//  build_system
//
//  Created by Jade Burton on 22.02.26.
//

struct StaticFile: InputlessNodeFunction, WithProperties {
    static let kind: UInt = 3

    let properties: [String: String]

    enum CodingKeys: CodingKey {
        case properties
    }

    var initialName: String {
        properties["path"]?.lastPathComponent ?? "untitled"
    }

    static let outputPort = "output"

    init() {
        properties = [String: String]()
    }

    init(properties: [String : String] = [String: String]()) {
        self.properties = properties
    }

//        func graphShapeArgs(node: Node) -> [GraphShapeArg] {
//            let path = (try? node.buildFullPathName()) ?? ""
//            return [GraphShapeArg(key: "path", value: path)]
//        }
    
    // When GraphShapeApplier needs to resolve "StaticFile(path: 'src/hello.c')", we receive properties with the path.
    // At that point we need to ensure the Folder hierarchy exists above us. Then we turn the path into a local name only.
    
    let descriptor = NodeFunctionDescriptor(staticInputPorts: [],
                                            outputPorts: [outputPort])

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
struct OutputFile: NodeFunction, WithProperties {

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

    var initialName: String {
        properties["path"]?.lastPathComponent ?? "untitled"
    }

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [inputPort], outputPorts: [statusOutputPort], dynamicInputPorts: [])

    func didCreate(node: Node) throws -> ProcessOutput {
        // OutputFile needs to be listable as part of a folder hierarchy, so we maintain that.

        // ensure a chain of Folders exist above us, all the way to "outputFileSystem" root Folder.

        let path = properties["path"]!
        let pathWithoutLastComponent = path // TODO

        // /outputFileSystem/bin/mylib.dylib
        try (Node.outputFileSystem.nodeFunctionCast() as Folder).ensureEntirePathExists(pathWithoutLastComponent, thisNode: Node.outputFileSystem)

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

protocol WithProperties {
    var properties: [String: String] { get }
    init(properties: [String: String])
}
