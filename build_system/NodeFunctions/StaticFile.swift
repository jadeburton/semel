//
//  StaticFile.swift
//  build_system
//
//  Created by Jade Burton on 22.02.26.
//

struct StaticFile: InputlessNodeFunction {
    static let kind: UInt = 3

    enum CodingKeys: CodingKey {
    }

    static let outputPort = "output"

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [],
                                            outputPorts: [outputPort])

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

struct Product: NodeFunction {
    static let kind: UInt = 8

    enum CodingKeys: CodingKey {
    }

    static let inputPort = "input"
    static let statusOutputPort = "status"

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [inputPort], outputPorts: [statusOutputPort], dynamicInputPorts: [])

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

// Like a StaticFile, but it allows you to put configuration directly into the formula.
struct Configuration: InputlessNodeFunction, WithProperties {
    static let kind: UInt = 9

    let properties: [String: String]

    enum CodingKeys: CodingKey {
        case properties
    }

    static let outputPort = "output"

    init() {
        properties = [String: String]()
    }

    init(properties: [String : String] = [String: String]()) {
        self.properties = properties
    }

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [], outputPorts: [outputPort], dynamicInputPorts: [])

    func didCreate(node: Node) throws -> ProcessOutput {

        let standardClang = ToolDescriptor(name: "clang",
                                           version: "Apple clang version 17.0.0 (clang-1700.6.3.2)",
                                           platform: "macOS",
                                           architecture: "arm64",
                                           recursiveHash: nil)

        func outputValue() throws -> PolySerializable {
            switch properties["tool"] {
                case "preprocessor":
                    return try ClangPreprocessorToolConfiguration(toolDescriptor: standardClang, arguments: [], environment: [:])
                case "linker":
                    return try ClangLinkerToolConfiguration(toolDescriptor: standardClang, arguments: [], environment: [:])
                case "compiler":
                    return try ClangCompilerToolConfiguration(toolDescriptor: standardClang, arguments: [], environment: [:])
                default:
                    return try ClangPreprocessorToolConfiguration(toolDescriptor: standardClang, arguments: [], environment: [:])
            }
        }
        return .init(outputValues: [Self.outputPort: .value(try outputValue().toJSON().intern())], inputWireExpectations: [:])
    }
}
