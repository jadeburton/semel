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

    static let inputPort = NodeKindDescriptor.InputPort(index: 0, name: "input", kind: .value(dataType: .utf8Text), maximumConnections: 1, minimumConnections: 0)
    static let outputPort = NodeKindDescriptor.OutputPort(index: 0, name: "output", kind: .value(dataType: .utf8Text))

    static let descriptor = NodeKindDescriptor(kind: kind, inputs: [inputPort], outputs: [outputPort])

    var descriptor: NodeKindDescriptor {
        Self.descriptor
    }

    // If this node receives a write to its one input, it immediately copies the value to its persistent output.
    // The input should not have any one-shot events, only persistent value changes
    func processInputs(_ inputs: [NodeKindDescriptor.InputPort: [NodeInputMessage]?]) throws -> [NodeKindDescriptor.OutputPort: NodeProcessPortOutput?] {
        assert(inputs.count == descriptor.inputs.count)

        guard let messagesOnInputPort = inputs[Self.inputPort]! else {
            // No messages means no value on this input
            return [:]
        }

        guard let oneMessageOnInputPort = messagesOnInputPort.first, messagesOnInputPort.count == 1 else {
            // More than one message queued - should be impossible
            return [:]
        }

        func outputValue() throws -> NodeProcessPortOutput? {
            switch oneMessageOnInputPort.kind {

            case .valueMutated(let delta):
                print("StaticFileNode received value mutation, delta hash: [\(delta ?? "nil")]")
                // StaticFile only supports a single connection on its input, and therefore has only one input value
                let value = try nodeContext.readValues(inputPort: Self.inputPort.index).first!!
                return .init(value: value, deltaMessage: delta)

            case .wireConnected:
                print("StaticFileNode received new wire")
                let value = try nodeContext.readValues(inputPort: Self.inputPort.index).first!!
                return .init(value: value, deltaMessage: nil)

            case .error(let description):
                print("StaticFileNode received error")
                return .init(value: .noValue(reason: .error(stack: [])), deltaMessage: nil)

            case .wireDisconnected:
                print("StaticFileNode lost input wire")
                return nil

            }
        }

        return [Self.outputPort: try outputValue()]
    }
}
