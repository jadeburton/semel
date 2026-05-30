
//
//  NodeDescriptor.swift
//  build_system
//

import Foundation

struct ErrorInfo {
    let nodeID: ObjectID
    let outputPort: UInt8
    let description: String
}

enum PortValueDataType: Codable, Hashable {
    case utf8Text
    case binary
    case json
    case custom(dataTypeName: String)
}

struct NodeKindDescriptor {
    enum PortKind: Codable, Hashable {
        case value(dataType: PortValueDataType)
        case stream(dataType: PortValueDataType)
    }

    struct InputPort: Codable, Hashable {
        let index: UInt8
        let name: String
        let kind: PortKind
        let maximumConnections: UInt8?
        let minimumConnections: UInt8
        let cascadingDelete: Bool
    }

    struct OutputPort: Codable, Hashable {
        let index: UInt8
        let name: String
        let kind: PortKind
    }

    let kind: UInt
    let inputs: [InputPort]
    let outputs: [OutputPort]
}

extension NodeKindDescriptor {
    func outputPort(named name: String) -> NodeKindDescriptor.OutputPort? {
        return outputs.first(where: { $0.name == name })
    }

    func inputPort(named name: String) -> NodeKindDescriptor.InputPort? {
        return inputs.first(where: { $0.name == name })
    }
}
