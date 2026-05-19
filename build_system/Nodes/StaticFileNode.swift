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

    static let outputPort = NodeKindDescriptor.OutputPort(index: 0, name: "output", kind: .value(dataType: .utf8Text))
    static let inputPort = NodeKindDescriptor.InputPort(index: 0, name: "input", kind: .value(dataType: .utf8Text), maximumConnections: 1, minimumConnections: 0)

    static let descriptor = NodeKindDescriptor(kind: kind, inputs: [inputPort], outputs: [outputPort])

    var descriptor: NodeKindDescriptor {
        Self.descriptor
    }

    func read() throws -> NodeValue? {
        try nodeContext.processingCycle.readFromOutputPort(Self.outputPort, nodeID: nodeContext.nodeID!)
    }

    func replaceContent(_ content: DataObjectHash, metadata: FileMetadata) throws {
        try writeToOutputPort(Self.outputPort,
                              value: .value(.dataObjectHash(content),
                                            metadata: metadata))
    }

    // If this node receives a write to its one input, it immediately copies the value to its persistent output.
    // The input should not have any one-shot events, only persistent value changes
    func process() throws {

        guard let inputValue = try readOneValueFromInputPort(Self.inputPort) else {
            // No input wire is connected.
            // Special case: instead of trashing our output with an error state, we just preserve the current value.
            if case .noValue = try readFromOutputPort(Self.outputPort).kind {
                try writeToOutputPort(Self.outputPort, value: .noValue(reason: .error(message: "Blah")))
            }
            return
        }

        if case .noValue = inputValue.kind {
            try writeToOutputPort(Self.outputPort, value: .noValue(reason: .error(message: "X")))
            return
        }

        // An input wire is connected
        try writeToOutputPort(Self.outputPort, value: inputValue.kind)
    }
}
