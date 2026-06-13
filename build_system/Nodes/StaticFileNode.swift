//
//  StaticFileNode.swift
//  build_system
//
//  Created by Jade Burton on 22.02.26.
//

final class StaticFileNode: NodeFunction {

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

    static let outputPort = "output"
    static let inputPort = "input"

    static let descriptor = NodeFunctionDescriptor(staticInputPorts: [inputPort], staticOutputPorts: [outputPort])

    var descriptor: NodeFunctionDescriptor {
        Self.descriptor
    }

    func read() throws -> NodeValue? {
        try nodeContext.processingCycle.readFromOutputPort(Self.outputPort, nodeID: self.nodeID)
    }

    func replaceContent(_ content: DataObjectHash) throws {
        try writeToOutputPort(Self.outputPort, value: .value(content))
    }

    func eraseContents() throws {
        try writeToOutputPort(Self.outputPort,
                              value: .noValue(reason: .error(message: "File deleted")))
    }

    // If this node receives a write to its one input, it immediately copies the value to its persistent output.
    func process() throws {
        do {
            let oneValue = try readOneValueFromInputPort(Self.inputPort)
            try writeToOutputPort(Self.outputPort, value: .value(oneValue.dataObjectHash))
        } catch NodeError.missingInputs {
            // No input wire is connected.
            // Special case: avoid trashing our output if it already has a value set
            if case .noValue = try readFromOutputPort(Self.outputPort).kind {
                throw NodeError.missingInputs
            }
        }
    }
}
