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

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [], outputPorts: [outputPort], dynamicInputPorts: [])

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

        return ProcessOutput(outputValues: [Self.statusOutputPort: outputValue], inputWireExpectations: [:])
    }
}
