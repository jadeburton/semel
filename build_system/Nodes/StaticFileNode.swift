//
//  StaticFileNode.swift
//  build_system
//
//  Created by Jade Burton on 22.02.26.
//

final class StaticFileNode: NodeType {

    static let kind: UInt = 3
    var nodeContext: NodeContext!

    enum CodingKeys: CodingKey {
    }

    required init() {
    }

    required init(from decoder: Decoder) throws {
        let _ = try decoder.container(keyedBy: CodingKeys.self)
        // StaticFileNode has no stored properties to decode (nodeContext is set separately)
    }

    func encode(to encoder: Encoder) throws {
        var _ = encoder.container(keyedBy: CodingKeys.self)
        // StaticFileNode has no stored properties to encode (nodeContext is not encoded)
    }

    static let outputPort = NodeKindDescriptor.OutputPort(index: 0,
                                                          name: "output",
                                                          kind: .value(dataType: .utf8Text))

    static let inputPort = NodeKindDescriptor.InputPort(index: 0,
                                                        name: "input",
                                                        kind: .value(dataType: .utf8Text),
                                                        maximumConnections: 1,
                                                        minimumConnections: 0,
                                                        cascadingDelete: false)

    static let descriptor = NodeKindDescriptor(kind: kind, inputs: [inputPort], outputs: [outputPort])

    var descriptor: NodeKindDescriptor {
        Self.descriptor
    }

    func read() throws -> NodeValue? {
        try nodeContext.processingCycle.readFromOutputPort(Self.outputPort, nodeID: nodeContext.nodeID!)
    }

    func replaceContent(_ content: DataObjectHash, metadata: String) throws {
        try writeToOutputPort(Self.outputPort, value: .value(content, metadata: metadata))
    }

    func eraseContents() throws {
        try writeToOutputPort(Self.outputPort,
                              value: .noValue(reason: .error(message: "File deleted")))
    }

    // If this node receives a write to its one input, it immediately copies the value to its persistent output.
    func process() throws {

        guard let inputValue = try readOneValueFromInputPort(Self.inputPort) else {
            // No input wire is connected.
            // Special case: avoid trashing our output if it has a value set
            if case .noValue = try readFromOutputPort(Self.outputPort).kind {
                throw NodeError.missingInputs
            }
            return
        }

        // An input wire is connected

        switch inputValue.kind {

        case .noValue:
            throw NodeError.missingInputs

        default:
            try writeToOutputPort(Self.outputPort, value: inputValue.kind)

        }
    }
}
