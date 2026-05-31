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
        var lines: [String] = []
        var visited = Set<BuildGraphNode>()
        describeInto(lines: &lines, indent: 0, visited: &visited)
        return lines.joined(separator: "\n")
    }

    // MARK: - Private recursive helper

    private func describeInto(lines: inout [String], indent: Int, visited: inout Set<BuildGraphNode>) {
        let prefix = String(repeating: "  ", count: indent)
        let marker = indent == 0 ? "⬢" : "▸"

        // Describe this node's kind as a short label
        let kindLabel: String
        switch kind {
        case .tool(let toolKind, _):
            switch toolKind {
            case .preprocessor: kindLabel = "[preprocessor]"
            case .compiler:     kindLabel = "[compiler]"
            case .linker:       kindLabel = "[linker]"
            }
        case .configuration(let config):
            kindLabel = "[config: \(config)]"
        case .inputFile:
            kindLabel = "[input file]"
        case .outputFile:
            kindLabel = "[output file]"
        }

        lines.append("\(prefix)\(marker) \(name) \(kindLabel)")

        // Guard against cycles in the graph
        guard !visited.contains(self) else {
            lines.append("\(prefix)  ↩ (already visited)")
            return
        }
        visited.insert(self)

        // Recurse into each input port and its wires
        let ports = inputPorts()
        for port in ports {
            lines.append("\(prefix)  ┌ port: \"\(port.name)\"")
            for wire in port.inputWires {
                lines.append("\(prefix)  │  ◀── from port \"\(wire.fromPort)\" of:")
                wire.from.describeInto(lines: &lines, indent: indent + 2, visited: &visited)
            }
            if port.inputWires.isEmpty {
                lines.append("\(prefix)  │  (no wires)")
            }
            lines.append("\(prefix)  └─────")
        }
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
    case multipleMatchingNodesBySearchKey
    case invalidPortNodeKind
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
