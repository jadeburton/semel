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
//  Wire endpoint (outputPort is non-nil) — used in expectation strings:
//      TypeName(portName=ShapeValue, portName=ShapeValue).outputPort
//      StaticFile('relative/path').outputPort
//
//  Node identity (outputPort is nil) — used for Node.searchKey:
//      TypeName(portName=ShapeValue, portName=ShapeValue)
//      StaticFile('relative/path')
//
//  The output port is a property of the *wire*, not of the node's upstream
//  topology.  Node.searchKey therefore stores the suffix-free form so that
//  the same searchKey is valid regardless of which output port a downstream
//  consumer wants to connect to.
//
//  Examples (wire-endpoint form):
//      StaticFile('src/hello.c').output
//      ClangPreprocessorTool(configuration=StaticFile('config.json').output,
//                            sourceFile=StaticFile('src/hello.c').output).output
//      ClangCompilerTool(configuration=StaticFile('config.json').output,
//                        input=ClangPreprocessorTool(...).output).output
//      ClangLinkerTool(input=[ClangCompilerTool(...).output,
//                             ClangCompilerTool(...).output]).output
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
    /// - inputs:     ordered list of connected input ports (only ports that have wires)
    /// - outputPort: which output port of this node is consumed downstream,
    ///               or `nil` when representing the node as a whole (e.g. searchKey)
    case tool(typeName: String, inputs: [GraphShapeInputPort], outputPort: String?)

    /// A static-file leaf node — no inputs, identified by its repo-relative path.
    /// - path:       repo-relative path, e.g. "src/hello.c"
    /// - outputPort: the output port consumed downstream, or `nil` for searchKey use
    case staticFile(path: String, outputPort: String?)
}

// MARK: - Serialisation

extension GraphShapeNode {

    /// Renders the node to a compact, human-readable string.
    /// When `outputPort` is non-nil the `.portName` suffix is appended (wire form).
    /// When `outputPort` is nil the suffix is omitted (searchKey / node-identity form).
    func asString() -> String {
        switch self {
        case .staticFile(let path, let outputPort):
            let suffix = outputPort.map { ".\($0)" } ?? ""
            return "StaticFile('\(path)')\(suffix)"

        case .tool(let typeName, let inputs, let outputPort):
            let suffix = outputPort.map { ".\($0)" } ?? ""
            if inputs.isEmpty {
                return "\(typeName)()\(suffix)"
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
            return "\(typeName)(\(portStrings.joined(separator: ", ")))\(suffix)"
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
    /// The trailing `.outputPort` suffix is optional — its absence sets `outputPort` to `nil`.
    static func parse(_ string: String) throws -> GraphShapeNode {
        var parser = GraphShapeParser(string)
        return try parser.parseNode()
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
            // StaticFile('path')[.outputPort]
            try consume("(")
            try consume("'")
            let path = try parseUntil("'")
            try consume("'")
            try consume(")")
            let outputPort = try parseOptionalOutputPort()
            return .staticFile(path: path, outputPort: outputPort)
        }

        // General node: TypeName(portList)[.outputPort]
        try consume("(")
        skipWhitespace()
        var inputs: [GraphShapeInputPort] = []
        if peek() != ")" {
            inputs = try parsePortList()
        }
        skipWhitespace()
        try consume(")")
        let outputPort = try parseOptionalOutputPort()
        return .tool(typeName: typeName, inputs: inputs, outputPort: outputPort)
    }

    // ── Optional trailing .outputPort ────────────────────────────────────────

    /// Reads `.identifier` if the next character is `.`, otherwise returns nil.
    mutating func parseOptionalOutputPort() throws -> String? {
        skipWhitespace()
        guard peek() == "." else { return nil }
        advance()   // consume '.'
        return try parseIdentifier()
    }

    // ── Port list ─────────────────────────────────────────────────────────────

    mutating func parsePortList() throws -> [GraphShapeInputPort] {
        var ports: [GraphShapeInputPort] = []
        ports.append(try parsePortEntry())
        while peek() == "," {
            advance()
            skipWhitespace()
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
            advance()
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
    /// builds a `GraphShapeNode` tree with the wire's output port set.
    /// Use this form when building expectation strings.
    static func buildFromWire(_ wire: Wire) throws -> GraphShapeNode {
        var visited = Set<ObjectID>()
        return try buildFromOrigin(fromNodeID: wire.fromNodeID,
                                   fromSymbolID: wire.fromSymbolID,
                                   includeOutputPort: true,
                                   visited: &visited)
    }

    /// Builds a `GraphShapeNode` tree rooted at `nodeID` with **no** output-port
    /// suffix — the node-identity / searchKey form.
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
            ? fromSymbolID!.resolveSymbol()
            : nil

        let sourceNode   = try fromNodeID.loadNode()
        let nodeFunction = try sourceNode.nodeFunction()
        let typeName     = String(describing: type(of: nodeFunction))

        // StaticFile leaf — identified by type; no inputs to recurse into.
        if nodeFunction is StaticFile {
            let path = try sourceNode.buildFullPathName()
            return .staticFile(path: path, outputPort: outputPortName)
        }

        // Guard against cycles.
        guard !visited.contains(fromNodeID) else {
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

            if incomingWires.count == 1 {
                var visitedCopy = visited
                let childNode = try buildFromOrigin(fromNodeID: incomingWires[0].fromNodeID,
                                                    fromSymbolID: incomingWires[0].fromSymbolID,
                                                    includeOutputPort: true,
                                                    visited: &visitedCopy)
                inputs.append(GraphShapeInputPort(portName: portName, value: .single(childNode)))
            } else {
                var childNodes: [GraphShapeNode] = []
                for incomingWire in incomingWires {
                    var branchVisited = visited
                    childNodes.append(try buildFromOrigin(fromNodeID: incomingWire.fromNodeID,
                                                          fromSymbolID: incomingWire.fromSymbolID,
                                                          includeOutputPort: true,
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
    /// matches this shape.  Returns `(fromNodeID, fromSymbolID)` ready to pass to
    /// `connectWire`, or `nil` if no matching node was found.
    ///
    /// `fromSymbolID` is derived from `outputPort` when non-nil; when `outputPort`
    /// is nil (searchKey form) `fromSymbolID` is also nil.
    func findMatchingNode() throws -> (fromNodeID: ObjectID, fromSymbolID: ObjectID?)? {
        switch self {

        case .staticFile(let path, let outputPort):
            let allNodes = try DatabaseLayer.shared.selectAllNodes()
            for node in allNodes {
                guard node.kind == StaticFile.kind, let nodeID = node.id else { continue }
                let nodePath = (try? node.buildFullPathName()) ?? ""
                if nodePath == path {
                    return (fromNodeID: nodeID,
                            fromSymbolID: outputPort.map { $0.asSymbolID() })
                }
            }
            return nil

        case .tool(let typeName, _, let outputPort):
            let allNodes = try DatabaseLayer.shared.selectAllNodes()
            let candidates = allNodes.filter { node in
                guard let fn = try? node.nodeFunction() else { return false }
                return String(describing: type(of: fn)) == typeName
            }
            for candidate in candidates {
                guard let nodeID = candidate.id else { continue }
                if try matchesNode(nodeID: nodeID) {
                    return (fromNodeID: nodeID,
                            fromSymbolID: outputPort.map { $0.asSymbolID() })
                }
            }
            return nil
        }
    }

    /// Returns `true` when the live node at `nodeID` matches this shape recursively.
    /// Comparison ignores `outputPort` — port is a wire property, not node identity.
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
}

// MARK: - Recompute searchKey for all nodes

extension DatabaseLayer {

    /// Recomputes `Node.searchKey` for every node in the database.
    ///
    /// The searchKey is the suffix-free graph-shape string for the node
    /// (no `.outputPort`), e.g.:
    ///   - `StaticFile('src/hello.c')`
    ///   - `ClangCompilerTool(configuration=StaticFile('config.json').output, input=...)`
    ///
    /// Skips writing when the value has not changed, so repeated calls are cheap.
    ///
    /// - Returns: the number of nodes whose `searchKey` was updated.
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
