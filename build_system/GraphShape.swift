//
//  GraphShape.swift
//  build_system
//
//  A lightweight, type-agnostic representation of the shape of a sub-graph
//  feeding one input wire.
//
//  String format
//  ─────────────
//  A node is serialised as:
//      TypeName(key='value', key='value', portName=ShapeValue, portName=[ShapeValue, ...]).outputPort
//
//  Parameters inside the parentheses are a flat, ordered list. Two kinds:
//    • Arg   — quoted string value   e.g.  path='src/hello.c'
//    • Input — node-reference value  e.g.  input=ClangCompilerTool(...).output
//
//  The trailing `.outputPort` suffix is optional:
//    • Present  → wire-endpoint form, used in expectation strings
//    • Absent   → node-identity form, stored in Node.searchKey
//
//  Examples:
//      StaticFile(path='src/hello.c').output
//      ClangPreprocessorTool(configuration=StaticFile(path='config.json').output,
//                            sourceFile=StaticFile(path='src/hello.c').output).output
//      ClangCompilerTool(configuration=StaticFile(path='config.json').output,
//                        input=ClangPreprocessorTool(...).output).output
//      ClangLinkerTool(input=[ClangCompilerTool(...).output, ClangCompilerTool(...).output]).output
//

import Foundation

// MARK: - Model

/// An initialization-time string argument, e.g. `path='src/hello.c'`.
struct GraphShapeArg: Equatable {
    let key:   String
    let value: String
}

/// A wired input port.
struct GraphShapeInputPort: Equatable {
    let portName: String
    let value:    GraphShapeInputValue
}

/// Single or multi-wire value for an input port.
indirect enum GraphShapeInputValue: Equatable {
    case single(GraphShapeNode)
    case multiple([GraphShapeNode])
}

/// A node in the graph-shape tree.
/// Represents any NodeFunction — the distinction between "tool" and "static file"
/// is expressed only through `typeName` and `args`.
struct GraphShapeNode: Equatable {
    /// Swift type name of the NodeFunction, e.g. `"StaticFile"`, `"ClangCompilerTool"`.
    let typeName:   String
    /// Init-time key-value arguments (e.g. `path='src/hello.c'`).  Ordered.
    let args:       [GraphShapeArg]
    /// Wired input ports.  Ordered.
    let inputs:     [GraphShapeInputPort]
    /// Output port consumed downstream, or `nil` for the node-identity / searchKey form.
    let outputPort: String?

    init(typeName: String,
         args:       [GraphShapeArg]       = [],
         inputs:     [GraphShapeInputPort] = [],
         outputPort: String?               = nil) {
        self.typeName   = typeName
        self.args       = args
        self.inputs     = inputs
        self.outputPort = outputPort
    }
}

// MARK: - Serialisation

extension GraphShapeNode {

    /// Renders the node to a compact string.
    func asString() -> String {
        let suffix = outputPort.map { ".\($0)" } ?? ""

        var params: [String] = []
        for arg in args {
            params.append("\(arg.key)='\(arg.value)'")
        }
        for input in inputs {
            switch input.value {
            case .single(let child):
                params.append("\(input.portName)=\(child.asString())")
            case .multiple(let children):
                let inner = children.map { $0.asString() }.joined(separator: ", ")
                params.append("\(input.portName)=[\(inner)]")
            }
        }

        return "\(typeName)(\(params.joined(separator: ", ")))\(suffix)"
    }
}

// MARK: - Parser

enum GraphShapeParseError: Error {
    case unexpectedCharacter(Character?, context: String)
    case unexpectedEndOfInput(context: String)
    case emptyIdentifier
}

extension GraphShapeNode {

    /// Parses a string produced by `asString()` back into a `GraphShapeNode`.
    static func parse(_ string: String) throws -> GraphShapeNode {
        var parser = GraphShapeParser(string)
        return try parser.parseNode()
    }
}

// MARK: - Recursive-descent parser implementation

private struct GraphShapeParser {

    private let chars: [Character]
    private var position: Int = 0

    init(_ string: String) { self.chars = Array(string) }

    // ── Entry ────────────────────────────────────────────────────────────────

    mutating func parseNode() throws -> GraphShapeNode {
        skipWhitespace()
        let typeName = try parseIdentifier()
        try consume("(")
        skipWhitespace()

        var args:   [GraphShapeArg]        = []
        var inputs: [GraphShapeInputPort]  = []

        if peek() != ")" {
            try parseParamList(into: &args, inputs: &inputs)
        }
        skipWhitespace()
        try consume(")")

        let outputPort = try parseOptionalOutputPort()
        return GraphShapeNode(typeName: typeName, args: args, inputs: inputs, outputPort: outputPort)
    }

    // ── Parameter list (mixed args and inputs) ────────────────────────────────

    mutating func parseParamList(into args: inout [GraphShapeArg],
                                 inputs: inout [GraphShapeInputPort]) throws {
        try parseOneParam(into: &args, inputs: &inputs)
        while peek() == "," {
            advance()                // consume ','
            skipWhitespace()
            guard peek() != ")" else { break }
            try parseOneParam(into: &args, inputs: &inputs)
        }
    }

    mutating func parseOneParam(into args: inout [GraphShapeArg],
                                inputs: inout [GraphShapeInputPort]) throws {
        skipWhitespace()
        let key = try parseIdentifier()
        skipWhitespace()
        try consume("=")
        skipWhitespace()

        if peek() == "'" {
            // Quoted string → arg
            advance()   // consume opening '
            let value = try parseUntil("'")
            advance()   // consume closing '
            args.append(GraphShapeArg(key: key, value: value))
        } else if peek() == "[" {
            // Array of nodes → multi-wire input
            advance()   // consume '['
            skipWhitespace()
            var children: [GraphShapeNode] = []
            if peek() != "]" {
                children.append(try parseNode())
                skipWhitespace()
                while peek() == "," {
                    advance()
                    skipWhitespace()
                    children.append(try parseNode())
                    skipWhitespace()
                }
            }
            try consume("]")
            inputs.append(GraphShapeInputPort(portName: key, value: .multiple(children)))
        } else {
            // Node reference → single-wire input
            let child = try parseNode()
            inputs.append(GraphShapeInputPort(portName: key, value: .single(child)))
        }
    }

    // ── Optional trailing .outputPort ────────────────────────────────────────

    mutating func parseOptionalOutputPort() throws -> String? {
        skipWhitespace()
        guard peek() == "." else { return nil }
        advance()
        return try parseIdentifier()
    }

    // ── Primitives ────────────────────────────────────────────────────────────

    mutating func parseIdentifier() throws -> String {
        skipWhitespace()
        var result = ""
        while let c = peek(), c.isLetter || c.isNumber || c == "_" {
            result.append(c); advance()
        }
        if result.isEmpty {
            throw GraphShapeParseError.emptyIdentifier
        }
        return result
    }

    mutating func parseUntil(_ stop: Character) throws -> String {
        var result = ""
        while let c = peek(), c != stop { result.append(c); advance() }
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

    mutating func skipWhitespace() { while let c = peek(), c.isWhitespace { advance() } }
    func peek() -> Character? { position < chars.count ? chars[position] : nil }
    mutating func advance() { position += 1 }
}

// MARK: - Build shape from the live graph

extension GraphShapeNode {

    static func buildFromWire(_ wire: Wire) throws -> GraphShapeNode {
        var visited = Set<ObjectID>()
        return try buildFromOrigin(fromNodeID: wire.fromNodeID,
                                   fromSymbolID: wire.fromSymbolID,
                                   includeOutputPort: true,
                                   visited: &visited)
    }

    /// Node-identity form (no output-port suffix) — used for `Node.searchKey`.
    static func buildFromNode(nodeID: ObjectID) throws -> GraphShapeNode {
        var visited = Set<ObjectID>()
        return try buildFromOrigin(fromNodeID: nodeID,
                                   fromSymbolID: nil,
                                   includeOutputPort: false,
                                   visited: &visited)
    }

    static func buildFromOrigin(fromNodeID: ObjectID,
                                fromSymbolID: ObjectID?,
                                includeOutputPort: Bool,
                                visited: inout Set<ObjectID>) throws -> GraphShapeNode {

        let outputPortName: String? = (includeOutputPort && fromSymbolID != nil)
            ? fromSymbolID!.resolveSymbol() : nil

        let sourceNode   = try fromNodeID.loadNode()
        let nodeFunction = try sourceNode.nodeFunction()
        let typeName     = String(describing: type(of: nodeFunction))

        // Guard against cycles.
        guard !visited.contains(fromNodeID) else {
            return GraphShapeNode(typeName: typeName, outputPort: outputPortName)
        }
        visited.insert(fromNodeID)

        // Extract init-time args from the node function.
        let args = nodeFunction.graphShapeArgs(node: sourceNode)

        // Recurse into every connected input port.
        let allInputPorts = nodeFunction.descriptor.staticInputPorts
                          + nodeFunction.descriptor.dynamicInputPorts

        var inputs: [GraphShapeInputPort] = []
        for portName in allInputPorts {
            let portSymbolID  = portName.asSymbolID()
            let incomingWires = try DatabaseLayer.shared.selectWires(goingToNodeID: fromNodeID,
                                                                     toSymbolID: portSymbolID)
            guard !incomingWires.isEmpty else { continue }

            if incomingWires.count == 1 {
                var visitedCopy = visited
                let child = try buildFromOrigin(fromNodeID: incomingWires[0].fromNodeID,
                                                fromSymbolID: incomingWires[0].fromSymbolID,
                                                includeOutputPort: true,
                                                visited: &visitedCopy)
                inputs.append(GraphShapeInputPort(portName: portName, value: .single(child)))
            } else {
                var children: [GraphShapeNode] = []
                for wire in incomingWires {
                    var branchVisited = visited
                    children.append(try buildFromOrigin(fromNodeID: wire.fromNodeID,
                                                        fromSymbolID: wire.fromSymbolID,
                                                        includeOutputPort: true,
                                                        visited: &branchVisited))
                }
                inputs.append(GraphShapeInputPort(portName: portName, value: .multiple(children)))
            }
        }

        return GraphShapeNode(typeName: typeName, args: args, inputs: inputs, outputPort: outputPortName)
    }
}

// MARK: - graphShapeArgs — extracting init-time arguments from a live node

extension InputlessNodeFunction {
    /// Returns the init-time key-value arguments that distinguish this node from
    /// others of the same type.  Override in concrete types that carry init-time
    /// state (e.g. `StaticFile` with its `path`).
    func graphShapeArgs(node: Node) -> [GraphShapeArg] { [] }
}

extension StaticFile {
    func graphShapeArgs(node: Node) -> [GraphShapeArg] {
        let path = (try? node.buildFullPathName()) ?? ""
        return [GraphShapeArg(key: "path", value: path)]
    }
}

// MARK: - Search for a matching node in the live graph

extension GraphShapeNode {

    func findMatchingNode() throws -> (fromNodeID: ObjectID, fromSymbolID: ObjectID?)? {
        let allNodes = try DatabaseLayer.shared.selectAllNodes()
        let candidates = allNodes.filter { node in
            guard let fn = try? node.nodeFunction() else { return false }
            return String(describing: type(of: fn)) == typeName
        }
        for candidate in candidates {
            guard let nodeID = candidate.id else { continue }
            if try matchesNode(nodeID: nodeID) {
                return (fromNodeID: nodeID,
                        fromSymbolID: outputPort?.asSymbolID())
            }
        }
        return nil
    }

    private func matchesNode(nodeID: ObjectID) throws -> Bool {
        let node         = try nodeID.loadNode()
        let nodeFunction = try node.nodeFunction()
        guard String(describing: type(of: nodeFunction)) == typeName else { return false }

        // Match init-time args.
        let actualArgs = nodeFunction.graphShapeArgs(node: node)
        guard actualArgs == args else { return false }

        // Match wired inputs recursively.
        for expectedPort in inputs {
            let portSymbolID = expectedPort.portName.asSymbolID()
            let actualWires  = try DatabaseLayer.shared.selectWires(goingToNodeID: nodeID,
                                                                    toSymbolID: portSymbolID)
            switch expectedPort.value {
            case .single(let expectedChild):
                guard actualWires.count == 1 else { return false }
                var visited: Set<ObjectID> = []
                let actualChild = try GraphShapeNode.buildFromOrigin(
                    fromNodeID: actualWires[0].fromNodeID,
                    fromSymbolID: actualWires[0].fromSymbolID,
                    includeOutputPort: true,
                    visited: &visited)
                guard actualChild == expectedChild else { return false }

            case .multiple(let expectedChildren):
                guard actualWires.count == expectedChildren.count else { return false }
                for (wire, expectedChild) in zip(actualWires, expectedChildren) {
                    var visited: Set<ObjectID> = []
                    let actualChild = try GraphShapeNode.buildFromOrigin(
                        fromNodeID: wire.fromNodeID,
                        fromSymbolID: wire.fromSymbolID,
                        includeOutputPort: true,
                        visited: &visited)
                    guard actualChild == expectedChild else { return false }
                }
            }
        }
        return true
    }
}

// MARK: - Find or create matching node in the live graph

extension GraphShapeNode {

    func findOrCreateMatchingNode() throws -> (fromNodeID: ObjectID, fromSymbolID: ObjectID?)? {
        if let existing = try findMatchingNode() { return existing }
        guard let newNodeID = try createNode() else { return nil }
        return (fromNodeID: newNodeID, fromSymbolID: outputPort?.asSymbolID())
    }

    private func createNode() throws -> ObjectID? {
        // Resolve kind from type name.
        let kind: UInt
        do {
            kind = try PolyFactory.kind(forTypeName: typeName)
        } catch {
            print("GraphShapeNode.createNode: unknown type '\(typeName)' — \(error)")
            return nil
        }

        if kind == StaticFile.kind {
            // Static file: find or create under inputFileSystem using the path arg.
            guard let pathArg = args.first(where: { $0.key == "path" }) else {
                print("GraphShapeNode.createNode: StaticFile missing 'path' arg")
                return nil
            }
            let inputFS = try Node.inputFileSystem
            guard let node = try inputFS.childNode(path: pathArg.value,
                                                    kind: StaticFile.kind,
                                                    createIfNotExist: true) else { return nil }
            return node.id
        }

        // Tool node: create as child of rootNode and wire up inputs recursively.
        let rootNode  = try Node.rootNode
        var newNode   = try Node.createNode(parentNodeID: rootNode.id!, kind: kind, name: typeName)
        let newNodeID = newNode.id!

        for inputPortSpec in inputs {
            let toSymbolID = inputPortSpec.portName.asSymbolID()

            switch inputPortSpec.value {
            case .single(let childShape):
                if let (fromNodeID, fromSymbolID) = try childShape.findOrCreateMatchingNode() {
                    guard let fromSymbolID else { continue }
                    try Wire.connectWire(fromNodeID: fromNodeID,
                                         fromSymbolID: fromSymbolID,
                                         toNodeID: newNodeID,
                                         toSymbolID: toSymbolID,
                                         name: inputPortSpec.portName.asSymbolID())
                }

            case .multiple(let childShapes):
                for (index, childShape) in childShapes.enumerated() {
                    let wireName = "\(inputPortSpec.portName)[\(index)]".asSymbolID()
                    if let (fromNodeID, fromSymbolID) = try childShape.findOrCreateMatchingNode() {
                        guard let fromSymbolID else { continue }
                        try Wire.connectWire(fromNodeID: fromNodeID,
                                             fromSymbolID: fromSymbolID,
                                             toNodeID: newNodeID,
                                             toSymbolID: toSymbolID,
                                             name: wireName)
                    }
                }
            }
        }

        try newNode.setScheduledAndSave(true)
        return newNodeID
    }
}

// MARK: - Recompute searchKey for all nodes

extension DatabaseLayer {

    @discardableResult
    public func recomputeAllSearchKeys() throws -> Int {
        let allNodes = try selectAllNodes()
        var updatedCount = 0
        for var node in allNodes {
            guard let nodeID = node.id else { continue }
            let newSearchKey: String?
            do {
                newSearchKey = try GraphShapeNode.buildFromNode(nodeID: nodeID).asString()
            } catch {
                print("recomputeAllSearchKeys: skipping node #\(nodeID) (\(node.name ?? "?")) — \(error)")
                newSearchKey = nil
            }
            guard node.searchKey != newSearchKey else { continue }
            node.searchKey = newSearchKey
            try updateNode(node)
            updatedCount += 1
        }
        return updatedCount
    }
}
