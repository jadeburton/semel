// BuildGraphDescription.swift
// build_system
//
// Data model types that describe the structure of a build graph before it is
// integrated into the live node/wire graph.

import Foundation

struct BuildGraphInputWire {
    let from: BuildGraphNode
    let fromPort: String
}

struct BuildGraphInputPort {
    let name: String
    let inputWires: [BuildGraphInputWire]
}

struct BuildGraphDescription {
    let outputs: [BuildGraphNode]
}

struct BuildGraphNode {
    let name: String
    let kind: BuildGraphNodeKind
}

enum BuildGraphNodeKind {
    case tool(kind: UInt, inputPorts: [BuildGraphInputPort])
    case configuration(_ configuration: String)
    case inputFile
    case outputFile(inputPorts: [BuildGraphInputPort])
}

enum BuildGraphError: Error {
    case unknownInputPortNameReference
}

extension BuildGraphNode {
    func inputPorts() -> [BuildGraphInputPort] {
        switch kind {
        case .tool(_, let inputPorts):
            return inputPorts
        case .outputFile(let inputPorts):
            return inputPorts
        case .configuration, .inputFile:
            return []
        }
    }
}
