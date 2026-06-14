//
//  GraphShape.swift
//  build_system
//
//  A lightweight, type-agnostic representation of the shape of a sub-graph
//  feeding one input wire. Used to compare the desired graph structure expressed
//  in a ProcessOutput.inputWireExpectation string against the actual wired graph,
//  and to search the live graph for a node matching a given expectation.
//
//  String format
//  ─────────────
//  General node:
//      TypeName(portName=ShapeValue, portName=ShapeValue).outputPort
//  Multiple-wire port value:
//      TypeName(portName=[ShapeValue, ShapeValue]).outputPort
//  Static file (leaf):
//      StaticFile('/relative/path').output
//
//  Examples:
//      StaticFile('/src/hello.c').output
//      Preprocessor(configuration=StaticFile('/config.json').output, sourceFile=StaticFile('/src/hello.c').output).output
//      Compiler(configuration=StaticFile('/config.json').output, input=Preprocessor(...).output).output
//      Linker(input=[Compiler(...).output, Compiler(...).output], libraries=StaticFile('/libSystem.tbd').output).output
//

import Foundation

// MARK: - Model

/// A single port entry inside a GraphShapeNode's input list.
struct GraphShapeInputPort: Equatable {
    let portName: String
    let value:    GraphShapeInputValue
}

/// The value wired into one input port — either a single upstream node or a
/// list of upstream nodes (for multi-wire dynamic ports).
indirect enum GraphShapeInputValue: Equatable {
    case single(GraphShapeNode)
    case multiple([GraphShapeNode])
}

/// A node in the graph-shape tree.
indirect enum GraphShapeNode: Equatable {

    /// Any node with named input ports.
    /// - typeName:   Swift type name of the NodeFunction (e.g. "ClangCompilerTool")
    /// - inputs:     ordered list of connected input ports
    /// - outputPort: name of the port on this node that is consumed further downstream
    case tool(typeName: String, inputs: [GraphShapeInputPort], outputPort: String)

    /// A static-file leaf node (has no inputs, identified by its repo-relative path).
    /// - path:       repo-relative path, e.g. "src/hello.c"
    /// - outputPort: always "output" in current usage, but kept flexible
    case staticFile(path: String, outputPort: String)
}

// MARK: - Serialisation

extension GraphShapeNode {

    /// Renders the node to a compact, human-readable string.
    func asString() -> String {
        switch self {
        case .staticFile(let path, let outputPort):
            return "StaticFile('\(path)').\(outputPort)"

        case .tool(let typeName, let inputs, let outputPort):
            if inputs.isEmpty {
                return "\(typeName)().\(outputPort)"
            }
            let portStrings = inputs.map { port -> String in
                switch port.value {
                case .single(let child):
                    return "\(port.portName)=\(child.asString())"
                case .multiple(let children):
                    let childStrings = children.map { $0.asString() }.joined(separator: ", ")
                    return "\(port.portName)=[\(childStrings)]"
                }
            }
            return "\(typeName)(\(portStrings.joined(separator: ", "))).\(outputPort)"
        }
    }
}

// MARK: - Parser

enum GraphShapeParseError: Error {
    case unexpectedCharacter(Character?, context: String)
    case unexpectedEndOfInput(context: String)
    case emptyTypeName
    case emptyPortName
}

extension GraphShapeNode {

    /// Parses a string produced by `asString()` back into a `GraphShapeNode`.
    static func parse(_ string: String) throws -> GraphShapeNode {
        var parser = GraphShapeParser(string)
        let node = try parser.parseNode()
        return node
    }
}

// MARK: - Recursive-descent parser implementation

private struct GraphShapeParser {

    private let chars: [Character]
    private var position: Int = 0

    init(_ string: String) {
        self.chars = Array(string)
    }

    // ── Public entry point ───────────────────────────────────────────────────

    mutating func parseNode() throws -> GraphShapeNode {
        skipWhitespace()
        let typeName = try parseIdentifier()

        if typeName == "StaticFile" {
            // StaticFile('/path').outputPort
            try consume("(")
            try consume("'")
            let path = try parseUntil("'")
            try consume("'")
            try consume(")")
            try consume(".")
            let outputPort = try parseIdentifier()
            return .staticFile(path: path, outputPort: outputPort)
        }

        // General node: TypeName(portList).outputPort
        try consume("(")
        skipWhitespace()
        var inputs: [GraphShapeInputPort] = []
        if peek() != ")" {
            inputs = try parsePortList()
        }
        skipWhitespace()
        try consume(")")
        try consume(".")
        let outputPort = try parseIdentifier()
        return .tool(typeName: typeName, inputs: inputs, outputPort: outputPort)
    }

    // ── Port list ─────────────────────────────────────────────────────────────

    mutating func parsePortList() throws -> [GraphShapeInputPort] {
        var ports: [GraphShapeInputPort] = []
        ports.append(try parsePortEntry())
        while peek() == "," {
            advance()          // consume ','
            skipWhitespace()
            // Stop if we accidentally hit the closing ')' (shouldn't happen with well-formed input)
            guard peek() != ")" else { break }
            ports.append(try parsePortEntry())
        }
        return ports
    }

    mutating func parsePortEntry() throws -> GraphShapeInputPort {
        skipWhitespace()
        let portName = try parseIdentifier()
        skipWhitespace()
        try consume("=")
        skipWhitespace()
        let value = try parsePortValue()
        return GraphShapeInputPort(portName: portName, value: value)
    }

    mutating func parsePortValue() throws -> GraphShapeInputValue {
        skipWhitespace()
        if peek() == "[" {
            advance()      // consume '['
            skipWhitespace()
            var nodes: [GraphShapeNode] = []
            if peek() != "]" {
                nodes.append(try parseNode())
                skipWhitespace()
                while peek() == "," {
                    advance()
                    skipWhitespace()
                    nodes.append(try parseNode())
                    skipWhitespace()
                }
            }
            try consume("]")
            return .multiple(nodes)
        } else {
            return .single(try parseNode())
        }
    }

    // ── Primitives ─────────────────────────────────────────────────────────────

    mutating func parseIdentifier() throws -> String {
        skipWhitespace()
        var result = ""
        while let c = peek(), c.isLetter || c.isNumber || c == "_" {
            result.append(c)
            advance()
        }
        if result.isEmpty { throw GraphShapeParseError.emptyTypeName }
        return result
    }

    /// Reads all characters until (but not including) `stopChar`.
    mutating func parseUntil(_ stopChar: Character) throws -> String {
        var result = ""
        while let c = peek(), c != stopChar {
            result.append(c)
            advance()
        }
        return result
    }

    mutating func consume(_ expected: Character) throws {
        guard let c = peek() else {
            throw GraphShapeParseError.unexpectedEndOfInput(context: "expected '\(expected)'")
        }
        guard c == expected else {
            throw GraphShapeParseError.unexpectedCharacter(c, context: "expected '\(expected)'")
        }
        advance()
    }

    mutating func skipWhitespace() {
        while let c = peek(), c.isWhitespace { advance() }
    }

    func peek() -> Character? {
        guard position < chars.count else { return nil }
        return chars[position]
    }

    mutating func advance() {
        position += 1
    }
}

// MARK: - Build shape from the live graph

extension GraphShapeNode {

    /// Walks the graph backwards from `wire.fromNodeID / wire.fromSymbolID` and
    /// builds a `GraphShapeNode` tree describing the sub-graph that feeds the wire.
    static func buildFromWire(_ wire: Wire) throws -> GraphShapeNode {
        var visited = Set<ObjectID>()
        return try buildFromOrigin(fromNodeID: wire.fromNodeID,
                                   fromSymbolID: wire.fromSymbolID,
                                   visited: &visited)
    }

    // Forward the recursive call so it is accessible from `matchesNode`.
//    private static func buildFromOrigin(fromNodeID: ObjectID,
//                                        fromSymbolID: ObjectID,
//                                        visited: inout Set<ObjectID>) throws -> GraphShapeNode {
//        try GraphShapeNode.buildFromOrigin(fromNodeID: fromNodeID,
//                                           fromSymbolID: fromSymbolID,
//                                           visited: &visited)
//    }

    private static func buildFromOrigin(fromNodeID: ObjectID,
                                        fromSymbolID: ObjectID,
                                        visited: inout Set<ObjectID>) throws -> GraphShapeNode {
        let outputPortName = fromSymbolID.resolveSymbol()
        let sourceNode     = try fromNodeID.loadNode()
        let nodeFunction   = try sourceNode.nodeFunction()
        let typeName       = String(describing: type(of: nodeFunction))

        // StaticFile leaf — identified by type; no inputs to recurse into.
        if nodeFunction is StaticFile {
            let path = try sourceNode.buildFullPathName()
            return .staticFile(path: path, outputPort: outputPortName)
        }

        // Guard against cycles in the graph (should not arise in a valid build graph
        // but protects against infinite recursion if the DB ever contains one).
        guard !visited.contains(fromNodeID) else {
            // Return a leaf placeholder so we don't loop forever.
            return .tool(typeName: typeName, inputs: [], outputPort: outputPortName)
        }
        visited.insert(fromNodeID)

        // Recurse into every connected input port.
        let allInputPorts = nodeFunction.descriptor.staticInputPorts
                          + nodeFunction.descriptor.dynamicInputPorts

        var inputs: [GraphShapeInputPort] = []
        for portName in allInputPorts {
            let portSymbolID  = portName.asSymbolID()
            let incomingWires = try DatabaseLayer.shared.selectWires(goingToNodeID: fromNodeID,
                                                                     toSymbolID: portSymbolID)
            guard !incomingWires.isEmpty else { continue }

            var visitedCopy = visited          // each branch gets its own copy to allow diamonds
            if incomingWires.count == 1 {
                let childNode = try buildFromOrigin(fromNodeID: incomingWires[0].fromNodeID,
                                                    fromSymbolID: incomingWires[0].fromSymbolID,
                                                    visited: &visitedCopy)
                inputs.append(GraphShapeInputPort(portName: portName, value: .single(childNode)))
            } else {
                var childNodes: [GraphShapeNode] = []
                for incomingWire in incomingWires {
                    var branchVisited = visited
                    childNodes.append(try buildFromOrigin(fromNodeID: incomingWire.fromNodeID,
                                                          fromSymbolID: incomingWire.fromSymbolID,
                                                          visited: &branchVisited))
                }
                inputs.append(GraphShapeInputPort(portName: portName, value: .multiple(childNodes)))
            }
        }

        return .tool(typeName: typeName, inputs: inputs, outputPort: outputPortName)
    }
}

// MARK: - Search for a matching node in the live graph

extension GraphShapeNode {

    /// Searches the live graph for a node whose type and recursive input wiring
    /// matches this `GraphShapeNode`.  Returns the `(fromNodeID, fromSymbolID)` pair
    /// that can be used as the wire origin, or `nil` if no match was found.
    func findMatchingNode() throws -> (fromNodeID: ObjectID, fromSymbolID: ObjectID)? {
        switch self {

        case .staticFile(let path, let outputPort):
            // Find a StaticFile node whose repo-relative path equals `path`.
            let allNodes = try DatabaseLayer.shared.selectAllNodes()
            for node in allNodes {
                guard node.kind == StaticFile.kind, let nodeID = node.id else { continue }
                let nodePath = (try? node.buildFullPathName()) ?? ""
                if nodePath == path {
                    return (fromNodeID: nodeID, fromSymbolID: outputPort.asSymbolID())
                }
            }
            return nil

        case .tool(let typeName, let expectedInputs, let outputPort):
            // Find all nodes whose NodeFunction type name matches.
            let allNodes = try DatabaseLayer.shared.selectAllNodes()
            let candidates = allNodes.filter { node in
                guard let fn = try? node.nodeFunction() else { return false }
                return String(describing: type(of: fn)) == typeName
            }
            for candidate in candidates {
                guard let nodeID = candidate.id else { continue }
                if try self.matchesNode(nodeID: nodeID) {
                    return (fromNodeID: nodeID, fromSymbolID: outputPort.asSymbolID())
                }
            }
            return nil
        }
    }

    /// Returns `true` when the live node identified by `nodeID` matches this shape recursively.
    private func matchesNode(nodeID: ObjectID) throws -> Bool {
        switch self {

        case .staticFile(let path, _):
            let node = try nodeID.loadNode()
            guard node.kind == StaticFile.kind else { return false }
            return ((try? node.buildFullPathName()) ?? "") == path

        case .tool(let typeName, let expectedInputs, _):
            let node         = try nodeID.loadNode()
            let nodeFunction = try node.nodeFunction()
            guard String(describing: type(of: nodeFunction)) == typeName else { return false }

            for expectedPort in expectedInputs {
                let portSymbolID  = expectedPort.portName.asSymbolID()
                let actualWires   = try DatabaseLayer.shared.selectWires(goingToNodeID: nodeID,
                                                                         toSymbolID: portSymbolID)
                switch expectedPort.value {
                case .single(let expectedChild):
                    guard actualWires.count == 1 else { return false }
                    let wire = actualWires[0]
                    var visited: Set<ObjectID> = []
                    let actualChild = try GraphShapeNode.buildFromOrigin(fromNodeID: wire.fromNodeID,
                                                                         fromSymbolID: wire.fromSymbolID,
                                                                         visited: &visited)
                    guard actualChild == expectedChild else { return false }

                case .multiple(let expectedChildren):
                    guard actualWires.count == expectedChildren.count else { return false }
                    // Order-dependent match — the order in which wires are stored in the DB
                    // is assumed to reflect insertion order.
                    for (wire, expectedChild) in zip(actualWires, expectedChildren) {
                        var visited: Set<ObjectID> = []
                        let actualChild = try GraphShapeNode.buildFromOrigin(fromNodeID: wire.fromNodeID,
                                                                             fromSymbolID: wire.fromSymbolID,
                                                                             visited: &visited)
                        guard actualChild == expectedChild else { return false }
                    }
                }
            }
            return true
        }
    }
}
