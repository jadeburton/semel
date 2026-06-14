//
//  StaticFile.swift
//  build_system
//
//  Created by Jade Burton on 22.02.26.
//

struct StaticFile: NodeFunction {

    static let kind: UInt = 3

    enum CodingKeys: CodingKey {
    }

    init() {
    }

    init(from decoder: Decoder) throws {
        let _ = try decoder.container(keyedBy: CodingKeys.self)
        // StaticFileNode has no stored properties to decode (nodeContext is set separately)
    }

    func encode(to encoder: Encoder) throws {
        var _ = encoder.container(keyedBy: CodingKeys.self)
        // StaticFileNode has no stored properties to encode (nodeContext is not encoded)
    }

    static let outputPort = "output"

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [], outputPorts: [outputPort], dynamicInputPorts: [])

    func read(thisNode: Node) throws -> NodeValue? {
        try thisNode.readFromOutputPort(Self.outputPort)
    }

    func replaceContent(thisNode: Node, _ content: DataObjectHash) throws {
        try thisNode.writeToOutputPort(Self.outputPort,
                                   value: .value(content),
                                   database: database)
    }

    func eraseContents(thisNode: Node) throws {
        try thisNode.writeToOutputPort(Self.outputPort,
                                   value: .noValue(reason: .error(message: "File deleted")),
                                   database: database)
    }

    func process(input: ProcessInput) throws -> ProcessOutput {
        throw NodeError.processNotSupported
    }
}
