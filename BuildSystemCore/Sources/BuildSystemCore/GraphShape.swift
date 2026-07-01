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
//      TypeName(key: 'value', portName <- ["wireName": ShapeNode, ...]).outputPort
//
//  Parameters inside the parentheses are a flat, ordered list.  Three kinds:
//    • Arg    — init-time quoted value    e.g.  path: 'src/hello.c'
//    • Input  — named-wire array         e.g.  input <- ["hello.c": StaticFile(...).output]
//    • Output — output expectation       e.g.  output -> ["result": StaticFile(...)]
//               (parsed and stored; not yet used in topology matching)
//
//  Each element inside an input/output array is a named wire entry:
//      "wireName": ShapeNode
//  Wire names correspond to Wire.name in the database and uniquely identify
//  each wire feeding a given port when multiple wires are present.
//
//  The trailing `.outputPort` suffix is optional:
//    • Present  → wire-endpoint form, used in expectation strings
//    • Absent   → node-identity form, stored in Node.searchKey
//
//
//  Examples:
//      StaticFile(path: 'src/hello.c').output
//      ClangPreprocessorTool(
//          configuration <- ["config": Configuration(tool: 'preprocessor').output],
//          input <- ["hello.c": StaticFile(path: 'hello.c').output]).output
//      ClangLinkerTool(
//          input <- ["compiler_hello": ClangCompilerTool(...).output,
//                    "compiler_main":  ClangCompilerTool(...).output]).output
//

import Foundation

// MARK: - Model

/// An initialization-time string argument, e.g. `path: 'src/hello.c'`.
struct GraphShapeArg: Equatable, Hashable {
    let key:   String
    let value: String
}

/// A single named wire feeding an input port.
struct GraphShapeWire: Equatable {
    let name: String          // wire name, e.g. "src/hello.c"
    let node: GraphShapeNode  // the upstream node
}

/// A wired input port.  `wires` holds all named wires feeding this port.
struct GraphShapeInputPort: Equatable {
    let portName: String
    let wires:    [GraphShapeWire]
}

/// An expected output port entry (future use — parsed but not yet matched).
struct GraphShapeOutputPort: Equatable {
    let portName: String
    let wires:    [GraphShapeWire]
}

/// A node in the graph-shape tree.
public struct GraphShapeNode: Equatable {
    /// Swift type name of the NodeFunction, e.g. `"StaticFile"`, `"ClangCompilerTool"`.
    let typeName:   String
    /// Init-time key-value arguments (e.g. `path: 'src/hello.c'`).  Ordered.
    let args:       [GraphShapeArg]
    /// Wired input ports.  Ordered.
    let inputs:     [GraphShapeInputPort]
    /// Expected output ports (future use — stored but not yet matched).
    let outputs:    [GraphShapeOutputPort]
    /// Output port consumed downstream, or `nil` for the node-identity / searchKey form.
    let outputPort: String?

    init(typeName:   String,
         args:       [GraphShapeArg]        = [],
         inputs:     [GraphShapeInputPort]  = [],
         outputs:    [GraphShapeOutputPort] = [],
         outputPort: String?                = nil) {
        self.typeName   = typeName
        self.args       = args
        self.inputs     = inputs
        self.outputs    = outputs
        self.outputPort = outputPort
    }
}

// MARK: - Serialisation

extension GraphShapeNode {

    /// Renders the node to a string.
    /// - Parameter pretty: When `true`, output is indented for human readability.
    ///   When `false` (default), output is compact and suitable for DB storage.
    func asString(pretty: Bool = false, omitOutputPort: Bool) -> String {
        asString(pretty: pretty, depth: 0, omitOutputPort: omitOutputPort)
    }

    private func asString(pretty: Bool, depth: Int, omitOutputPort: Bool) -> String {
        let suffix    = omitOutputPort ? "" : (outputPort.map { ".\($0)" } ?? "")
        let indent    = pretty ? String(repeating: "  ", count: depth + 1) : ""
        let closing   = pretty ? "\n\(String(repeating: "  ", count: depth))" : ""
        let separator = pretty ? ",\n\(indent)" : ", "

        var params: [String] = []

        // Args: key: 'value'
        for arg in args {
            params.append("\(arg.key): '\(arg.value)'")
        }

        // Inputs: portName <- ["wireName": Node, ...]
        for input in inputs {
            let wireStrings = input.wires.map { wire in
                "\"\(wire.name)\": \(wire.node.asString(pretty: pretty, depth: depth + 1, omitOutputPort: false))"
            }
            let inner = pretty
                ? "\n\(indent)\(wireStrings.joined(separator: separator))\n\(String(repeating: "  ", count: depth))"
                : wireStrings.joined(separator: separator)
            params.append("\(input.portName) <- [\(inner)]")
        }

        // Outputs: portName -> ["wireName": Node, ...] (future use)
        for output in outputs {
            let wireStrings = output.wires.map { wire in
                "\"\(wire.name)\": \(wire.node.asString(pretty: pretty, depth: depth + 1, omitOutputPort: false))"
            }
            let inner = pretty
                ? "\n\(indent)\(wireStrings.joined(separator: separator))\n\(String(repeating: "  ", count: depth))"
                : wireStrings.joined(separator: separator)
            params.append("\(output.portName) -> [\(inner)]")
        }

        let joinedParams = params.isEmpty
            ? ""
            : pretty
                ? "\n\(indent)\(params.joined(separator: separator))\(closing)"
                : params.joined(separator: separator)

        return "\(typeName)(\(joinedParams))\(suffix)"
    }
}

// MARK: - Topology comparison (structural, port-order-independent)

extension GraphShapeNode {

    /// Returns `true` when `self` and `other` describe the same graph topology,
    /// including wire names.  `outputPort` and `outputs` are intentionally ignored —
    /// output expectations are not yet matched.
    func topologyMatches(_ other: GraphShapeNode) -> Bool {
        guard typeName == other.typeName   else { return false }
        guard Set(args) == Set(other.args) else { return false }

        let selfPorts  = Dictionary(inputs.map       { ($0.portName, $0.wires) },
                                    uniquingKeysWith: { first, _ in first })
        let otherPorts = Dictionary(other.inputs.map { ($0.portName, $0.wires) },
                                    uniquingKeysWith: { first, _ in first })

        guard selfPorts.count == otherPorts.count else { return false }

        for (portName, selfWires) in selfPorts {
            guard let otherWires = otherPorts[portName]  else { return false }
            guard selfWires.count == otherWires.count    else { return false }
            for (selfWire, otherWire) in zip(selfWires, otherWires) {
                guard selfWire.name == otherWire.name              else { return false }
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
    public static func parse(_ string: String) throws -> GraphShapeNode {
        var parser = GraphShapeParser(string)
        return try parser.parseNode()
    }
}

// MARK: - Recursive-descent parser

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

        var args:    [GraphShapeArg]        = []
        var inputs:  [GraphShapeInputPort]  = []
        var outputs: [GraphShapeOutputPort] = []

        if peek() != ")" {
            try parseParamList(args: &args, inputs: &inputs, outputs: &outputs)
        }
        skipWhitespace()
        try consume(")")

        let outputPort = try parseOptionalOutputPort()
        return GraphShapeNode(typeName:   typeName,
                              args:       args,
                              inputs:     inputs,
                              outputs:    outputs,
                              outputPort: outputPort)
    }

    // ── Parameter list ────────────────────────────────────────────────────────

    mutating func parseParamList(args:    inout [GraphShapeArg],
                                 inputs:  inout [GraphShapeInputPort],
                                 outputs: inout [GraphShapeOutputPort]) throws {
        try parseOneParam(args: &args, inputs: &inputs, outputs: &outputs)
        while peek() == "," {
            advance()
            skipWhitespace()
            guard peek() != ")" else { break }
            try parseOneParam(args: &args, inputs: &inputs, outputs: &outputs)
        }
    }

    /// Parse one parameter.  Operator determines kind:
    ///
    ///   `key: 'value'`   → arg
    ///   `key <- [...]`   → input
    ///   `key -> [...]`   → output (future use)
    mutating func parseOneParam(args:    inout [GraphShapeArg],
                                inputs:  inout [GraphShapeInputPort],
                                outputs: inout [GraphShapeOutputPort]) throws {
        skipWhitespace()
        let key = try parseIdentifier()
        skipWhitespace()

        if peek() == ":" {
            // arg:  key: 'value'
            advance()
            skipWhitespace()
            let value = try parseQuotedString()
            args.append(GraphShapeArg(key: key, value: value))

        } else if peek() == "<" {
            // input:  key <- [...]
            advance()           // consume '<'
            try consume("-")   // consume '-'
            skipWhitespace()
            let wires = try parseWireArray()
            inputs.append(GraphShapeInputPort(portName: key, wires: wires))

        } else if peek() == "-" {
            // output:  key -> [...]
            advance()           // consume '-'
            try consume(">")   // consume '>'
            skipWhitespace()
            let wires = try parseWireArray()
            outputs.append(GraphShapeOutputPort(portName: key, wires: wires))

        } else {
            throw GraphShapeParseError.unexpectedCharacter(
                peek(), context: "expected ':', '<-', or '->' after key '\(key)'. Parsing: \(String(chars))")
        }
    }

    // ── Wire array: [ entry, entry, ... ] ────────────────────────────────────

    mutating func parseWireArray() throws -> [GraphShapeWire] {
        try consume("[")
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
        return wires
    }

    // ── Wire entry: "name": Node ─────────────────────────────────────────────

    mutating func parseWireEntry() throws -> GraphShapeWire {
        skipWhitespace()
        let wireName = try parseQuotedString()
        skipWhitespace()
        try consume(":")
        skipWhitespace()
        let node = try parseNode()
        return GraphShapeWire(name: wireName, node: node)
    }

    // ── Quoted string (single or double quotes) ───────────────────────────────

    mutating func parseQuotedString() throws -> String {
        guard let quote = peek(), quote == "'" || quote == "\"" else {
            throw GraphShapeParseError.unexpectedCharacter(
                peek(), context: "expected quoted string. Parsing: \(String(chars))")
        }
        advance()
        let value = try parseUntil(quote)
        advance()   // closing quote
        return value
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
