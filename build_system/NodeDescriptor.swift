
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

enum PortKind: Codable, Hashable {
    case value(dataType: PortValueDataType)
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

struct NodeKindDescriptor {
    let kind: UInt
    let inputs: [InputPort]
    let outputs: [OutputPort]
}

extension NodeKindDescriptor {
    func outputPort(named name: String) -> OutputPort? {
        return outputs.first(where: { $0.name == name })
    }

    func inputPort(named name: String) -> InputPort? {
        return inputs.first(where: { $0.name == name })
    }
}
