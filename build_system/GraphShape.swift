//
//  GraphShape.swift
//  build_system
//
//  Pure model, serialisation, topology comparison, and parser for graph shapes.
//  No database or live-graph access — see GraphShapeApplier.swift for that.
//
//  String format
//  ─────────────
//  A node is serialised as:
//      TypeName(key='value', portName=["wireName":ShapeNode, ...]).outputPort
//
//  Parameters inside the parentheses are a flat, ordered list. Two kinds:
//    • Arg   — quoted string value     e.g.  path='src/hello.c'
//    • Input — named-wire array        e.g.  input=["hello.c":StaticFile(...).output]
//
//  Each element inside an input array is a named wire entry:
//      "wireName":ShapeNode
//  Wire names correspond to Wire.name in the database and uniquely identify
//  each wire feeding a given input port when multiple wires are present.
//
//  The trailing `.outputPort` suffix is optional:
//    • Present  → wire-endpoint form, used in expectation strings
//    • Absent   → node-identity form, stored in Node.searchKey
//
//  Examples:
//      StaticFile(path='src/hello.c').output
//      ClangPreprocessorTool(
//          configuration=["Configuration":Configuration(tool='preprocessor').output],
//          input=["hello.c":StaticFile(path='hello.c').output]).output
//      ClangLinkerTool(
//          input=["compiler_hello":ClangCompilerTool(...).output,
//                 "compiler_main":ClangCompilerTool(...).output]).output
//

import Foundation

// MARK: - Model

/// An initialization-time string argument, e.g. `path='src/hello.c'`.
struct GraphShapeArg: Equatable, Hashable {
    let key:   String
    let value: String
}

/// A single named wire feeding an input port.
/// The `name` corresponds to `Wire.name` in the database (resolved symbol string).
struct GraphShapeWire: Equatable {
    let name: String          // wire name, e.g. "hello.c"
    let node: GraphShapeNode  // the upstream node
}

/// A wired input port.  `wires` holds all named wires feeding this port.
struct GraphShapeInputPort: Equatable {
    let portName: String
    let wires:    [GraphShapeWire]
}

/// A node in the graph-shape tree.
struct GraphShapeNode: Equatable {
    /// Swift type name of the NodeFunction, e.g. `"StaticFile"`, `"ClangCompilerTool"`.
    let typeName:   String
    /// Init-time key-value arguments (e.g. `path='src/hello.c'`).  Ordered.
    let args:       [GraphShapeArg]
    /// Wired input ports.  Ordered.
    let inputs:     [GraphShapeInputPort]
    /// Output port consumed downstream, or `nil` for the node-identity / searchKey form.
    let outputPort: String?

    init(typeName:   String,
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

    /// Renders the node to a string.
    /// - Parameter pretty: When `true`, output is indented for human readability.
    ///   When `false` (default), output is compact and suitable for DB storage.
    func asString(pretty: Bool = false) -> String {
        asString(pretty: pretty, depth: 0)
    }

    private func asString(pretty: Bool, depth: Int) -> String {
        let suffix     = outputPort.map { ".\($0)" } ?? ""
        let indent     = pretty ? String(repeating: "  ", count: depth + 1) : ""
        let closing    = pretty ? "\n\(String(repeating: "  ", count: depth))" : ""
        let separator  = pretty ? ",\n\(indent)" : ", "
        //let lineBreak  = pretty ? "\n\(indent)" : ""

        var params: [String] = []
        for arg in args {
            params.append("\(arg.key)='\(arg.value)'")
        }
        for input in inputs {
            let wires = input.wires.map { wire in
                "\"\(wire.name)\":\(wire.node.asString(pretty: pretty, depth: depth + 1))"
            }
            let inner = pretty
                ? "\n\(indent)\(wires.joined(separator: separator))\n\(String(repeating: "  ", count: depth))"
                : wires.joined(separator: separator)
            params.append("\(input.portName)=[\(inner)]")
        }

        let joinedParams = params.isEmpty ? "" : (pretty ? "\n\(indent)\(params.joined(separator: separator))\(closing)" : params.joined(separator: separator))
        return "\(typeName)(\(joinedParams))\(suffix)"
    }
}

// MARK: - Topology comparison (structural, port-order-independent)

extension GraphShapeNode {

    /// Returns `true` when `self` and `other` describe the same graph topology,
    /// including wire names.  `outputPort` is intentionally ignored — it belongs
    /// to the wire endpoint, not the node's identity.
    func topologyMatches(_ other: GraphShapeNode) -> Bool {
        guard typeName == other.typeName   else { return false }
        guard Set(args) == Set(other.args) else { return false }

        // Build port-name → wires dictionaries for order-independent comparison.
        let selfPorts  = Dictionary(inputs.map       { ($0.portName, $0.wires) },
                                    uniquingKeysWith: { first, _ in first })
        let otherPorts = Dictionary(other.inputs.map { ($0.portName, $0.wires) },
                                    uniquingKeysWith: { first, _ in first })

        guard selfPorts.count == otherPorts.count else { return false }

        for (portName, selfWires) in selfPorts {
            guard let otherWires = otherPorts[portName]         else { return false }
            guard selfWires.count == otherWires.count           else { return false }
            for (selfWire, otherWire) in zip(selfWires, otherWires) {
                // Only compare wire names when both sides supply one.
                // An empty name means the shape was serialised in the old
                // unnamed format; treat it as a wildcard so old expectation
                // strings continue to match against the new named format.
                if !selfWire.name.isEmpty && !otherWire.name.isEmpty {
                    guard selfWire.name == otherWire.name       else { return false }
                }
                guard selfWire.node.topologyMatches(otherWire.node) else { return false }
            }
        }
        return true
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

    // ── Entry ─────────────────────────────────────────────────────────────────

    mutating func parseNode() throws -> GraphShapeNode {
        skipWhitespace()
        let typeName = try parseIdentifier()
        try consume("(")
        skipWhitespace()

        var args:   [GraphShapeArg]       = []
        var inputs: [GraphShapeInputPort] = []

        if peek() != ")" {
            try parseParamList(into: &args, inputs: &inputs)
        }
        skipWhitespace()
        try consume(")")

        let outputPort = try parseOptionalOutputPort()
        return GraphShapeNode(typeName: typeName, args: args, inputs: inputs, outputPort: outputPort)
    }

    // ── Parameter list ────────────────────────────────────────────────────────

    mutating func parseParamList(into args: inout [GraphShapeArg],
                                 inputs: inout [GraphShapeInputPort]) throws {
        try parseOneParam(into: &args, inputs: &inputs)
        while peek() == "," {
            advance()
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

        if peek() == "'" || peek() == "\"" {
            // Quoted string → arg value (accept both quote styles for compatibility)
            let quote = peek()!
            advance()
            let value = try parseUntil(quote)
            advance()
            args.append(GraphShapeArg(key: key, value: value))
        } else if peek() == "[" {
            // Bracketed array → named-wire input array
            advance()
            skipWhitespace()
            var wires: [GraphShapeWire] = []
            if peek() != "]" {
                wires.append(try parseWireEntry())
                skipWhitespace()
                while peek() == "," {
                    advance()
                    skipWhitespace()
                    wires.append(try parseWireEntry())
                    skipWhitespace()
                }
            }
            try consume("]")
            inputs.append(GraphShapeInputPort(portName: key, wires: wires))
        } else {
            // Unbracketed single node → backward-compat unnamed wire
            let child = try parseNode()
            inputs.append(GraphShapeInputPort(portName: key,
                                              wires: [GraphShapeWire(name: "", node: child)]))
        }
    }

    // ── Wire entry: "name":Node  or  Node (old unnamed format) ───────────────

    mutating func parseWireEntry() throws -> GraphShapeWire {
        skipWhitespace()
        if peek() == "\"" || peek() == "'" {
            // New named format: "wireName":Node
            let quote = peek()!
            advance()
            let wireName = try parseUntil(quote)
            advance()       // closing quote
            skipWhitespace()
            try consume(":")
            skipWhitespace()
            let node = try parseNode()
            return GraphShapeWire(name: wireName, node: node)
        } else {
            // Old unnamed format: Node  (backward compatibility — name defaults to "")
            let node = try parseNode()
            return GraphShapeWire(name: "", node: node)
        }
    }

    // ── Optional trailing .outputPort ─────────────────────────────────────────

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
            throw GraphShapeParseError.unexpectedEndOfInput(
                context: "expected '\(expected)'. Parsing: \(String(chars))")
        }
        guard c == expected else {
            throw GraphShapeParseError.unexpectedCharacter(
                c, context: "expected '\(expected)'. Parsing: \(String(chars))")
        }
        advance()
    }

    mutating func skipWhitespace() { while let c = peek(), c.isWhitespace { advance() } }
    func     peek()    -> Character? { position < chars.count ? chars[position] : nil }
    mutating func advance() { position += 1 }
}
