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
        try writeToOutputPort(Self.outputPort, value: .init(originNodeID: nodeContext.nodeID!,
                                                            kind: .value(dataObjectHash: content,
                                                                         metadata: metadata)))
    }

    // If this node receives a write to its one input, it immediately copies the value to its persistent output.
    // The input should not have any one-shot events, only persistent value changes
    func processInputs(_ inputs: [NodeKindDescriptor.InputPort: [NodeMessage]?]) throws {
        assert(inputs.count == descriptor.inputs.count)

        guard let inputValue = try readFromInputPort(Self.inputPort).first else {
            try writeToOutputPort(Self.outputPort, value: .init(originNodeID: nodeContext.nodeID!, kind: .noValue(reason: .awaitingDependency)))
            return
        }

        switch inputValue.kind {

        case .noValue:
            try writeToOutputPort(Self.outputPort, value: .init(originNodeID: nodeContext.nodeID!, kind:.noValue(reason: .awaitingDependency)))
            return

        case .value:
            try writeToOutputPort(Self.outputPort, value: inputValue)

        }
    }
}
