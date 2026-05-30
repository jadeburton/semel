// BuildGraphDescription.swift
// build_system
//
// Data model types that describe the structure of a build graph before it is
// integrated into the live node/wire graph.

import Foundation

struct BuildGraphNode: Codable, Equatable, Hashable {
    let name: String
    let kind: BuildGraphNodeKind

    func describe() -> String {
        // TODO: recursively describe the entire graph structure rooted at this node, in a human-readable manner, i.e. a tree with indentation
        ""
    }
}

enum BuildGraphToolKind: Codable, Equatable, Hashable {
    case preprocessor
    case compiler
    case linker
}

enum BuildGraphNodeKind: Codable, Equatable, Hashable {
    case tool(kind: BuildGraphToolKind, inputPorts: [BuildGraphInputPort])
    case configuration(_ configuration: String)
    case inputFile
    case outputFile(inputPorts: [BuildGraphInputPort])
}

struct BuildGraphInputWire: Codable, Equatable, Hashable {
    let from: BuildGraphNode
    let fromPort: String
}

struct BuildGraphInputPort: Codable, Equatable, Hashable {
    let name: String
    let inputWires: [BuildGraphInputWire]
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
