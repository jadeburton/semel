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
//      TypeName(key='value', portName=[ShapeNode, ...]).outputPort
//
//  Parameters inside the parentheses are a flat, ordered list. Two kinds:
//    • Arg   — quoted string value   e.g.  path='src/hello.c'
//    • Input — node-reference value  e.g.  input=[ClangCompilerTool(...).output]
//
//  The trailing `.outputPort` suffix is optional:
//    • Present  → wire-endpoint form, used in expectation strings
//    • Absent   → node-identity form, stored in Node.searchKey
//
//  Examples:
//      StaticFile(path='src/hello.c').output
//      ClangPreprocessorTool(configuration=[StaticFile(path='config.json').output],
//                            sourceFile=[StaticFile(path='src/hello.c').output]).output
//      ClangLinkerTool(input=[ClangCompilerTool(...).output,
//                             ClangCompilerTool(...).output]).output
//

import Foundation

// MARK: - Model

/// An initialization-time string argument, e.g. `path='src/hello.c'`.
struct GraphShapeArg: Equatable, Hashable {
    let key:   String
    let value: String
}

/// A wired input port.  `value` holds all nodes wired to this port.
struct GraphShapeInputPort: Equatable {
    let portName: String
    let value:    [GraphShapeNode]
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

    /// Renders the node to a compact string.
    func asString() -> String {
        let suffix = outputPort.map { ".\($0)" } ?? ""

        var params: [String] = []
        for arg in args {
            params.append("\(arg.key)='\(arg.value)'")
        }
        for input in inputs {
            let inner = input.value.map { $0.asString() }.joined(separator: ", ")
            params.append("\(input.portName)=[\(inner)]")
        }

        return "\(typeName)(\(params.joined(separator: ", ")))\(suffix)"
    }
}

// MARK: - Topology comparison (structural, port-order-independent)

extension GraphShapeNode {

    /// Returns `true` when `self` and `other` describe the same graph topology.
    /// `outputPort` is intentionally ignored — it belongs to the wire, not the node.
    func topologyMatches(_ other: GraphShapeNode) -> Bool {
        guard typeName == other.typeName   else { return false }
        guard Set(args) == Set(other.args) else { return false }

        let selfPorts  = Dictionary(inputs.map       { ($0.portName, $0.value) },
                                    uniquingKeysWith: { first, _ in first })
        let otherPorts = Dictionary(other.inputs.map { ($0.portName, $0.value) },
                                    uniquingKeysWith: { first, _ in first })

        guard selfPorts.count == otherPorts.count else { return false }

        for (portName, selfChildren) in selfPorts {
            guard let otherChildren = otherPorts[portName]          else { return false }
            guard selfChildren.count == otherChildren.count         else { return false }
            for (selfChild, otherChild) in zip(selfChildren, otherChildren) {
                guard selfChild.topologyMatches(otherChild)         else { return false }
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
            // Quoted string → arg (accept both quote styles for compatibility)
            let quote = peek()!
            advance()
            let value = try parseUntil(quote)
            advance()
            args.append(GraphShapeArg(key: key, value: value))
        } else if peek() == "[" {
            // Bracketed array → input (canonical format)
            advance()
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
            inputs.append(GraphShapeInputPort(portName: key, value: children))
        } else {
            // Unbracketed single node → input (old format, kept for backward compatibility)
            let child = try parseNode()
            inputs.append(GraphShapeInputPort(portName: key, value: [child]))
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
