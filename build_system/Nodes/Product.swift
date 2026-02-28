//
//  Product.swift
//  build_system
//
//  Created by Jade Burton on 22.02.26.
//

/*
final class Product: NodeType {
    static let kind: UInt = 2

    var nodeContext: NodeContext!
    var dynamicInputs: [NodeKindDescriptor.InputPort]

    enum CodingKeys: String, CodingKey {
        case dynamicInputs
    }

    required init() {
        dynamicInputs = [
            .init(index: 0, name: "input", kind: .value(dataType: .binary), maximumConnections: 1, minimumConnections: 1)
        ]
    }

    // Adds a new input port effectively to the entire Graph
    func addInputPort(named name: String, kind: NodeKindDescriptor.PortKind) {
        dynamicInputs.append(.init(index: UInt8(dynamicInputs.count), name: name, kind: kind))
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dynamicInputs = try container.decode([NodeKindDescriptor.Port].self, forKey: .dynamicInputs)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dynamicInputs, forKey: .dynamicInputs)
    }

    var descriptor: NodeKindDescriptor {
        .init(kind: Self.kind, inputs: dynamicInputs, outputs: [])
    }

    func processInputs(_ inputs: [NodeKindDescriptor.InputPort: [NodeInputMessage]?]) throws -> [NodeKindDescriptor.OutputPort: NodeProcessPortOutput?] {
        [:]
    }
}*/
