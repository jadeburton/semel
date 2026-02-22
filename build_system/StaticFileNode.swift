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

    static let inputPort = NodeKindDescriptor.Port(index: 0, name: "input", kind: .persistentValue(dataType: .utf8Text))
    static let outputPort = NodeKindDescriptor.Port(index: 0, name: "output", kind: .persistentValue(dataType: .utf8Text))

    static let descriptor = NodeKindDescriptor(kind: kind, inputs: [inputPort], outputs: [outputPort])

    var descriptor: NodeKindDescriptor {
        Self.descriptor
    }

    // If this node receives a write to its one input, it immediately copies the value to its persistent output.
    // The input should not have any one-shot events, only persistent value changes
    func processInputs(_ inputs: [NodeKindDescriptor.Port: [NodeInputMessage]?]) throws -> [NodeKindDescriptor.Port: NodeOutputMessage?] {
        assert(inputs.count == descriptor.inputs.count)

        guard let messagesOnInputPort = inputs[Self.inputPort]! else {
            // No messages means no value on this input
            return [:]
        }

        guard let oneMessageOnInputPort = messagesOnInputPort.first, messagesOnInputPort.count == 1 else {
            // More than one message queued - should be impossible
            return [:]
        }

        func outputValue() -> NodeOutputMessage? {
            switch oneMessageOnInputPort.kind {

            case .valueMutated(let delta):
                print("StaticFileNode received value mutation, delta: [\(delta?.content.asHex() ?? "nil")]")
                return .valueMutation(delta)

            case .wireConnected(let currentValue):
                print("StaticFileNode received new wire")
                return .valueMutation(currentValue)

            case .error(let description):
                print("StaticFileNode received error")
                return .error(description: description)

            case .wireDisconnected:
                print("StaticFileNode lost input wire")
                return nil

            case .event(_):
                // This should not be possible, since the input port is not an event port, but if it happens, we just ignore it
                print("StaticFileNode got an event")
                return nil
            }
        }

        return [Self.outputPort: outputValue()]
    }
}
