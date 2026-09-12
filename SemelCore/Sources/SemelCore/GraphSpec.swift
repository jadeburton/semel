//
//  GraphSpec.swift
//  semel
//
//  Pure model, serialisation, topology comparison, and parser for graph specs.
//  No database or live-graph access — see GraphSpecApplier.swift for that.
//
//  String format
//  ─────────────
//  A node is serialised as:
//      TypeName(key: 'value', portName: ["wireName": ShapeNode, ...]).outputPort
//
//  Parameters inside the parentheses are a flat, ordered list.  Three kinds:
//    • Arg    — init-time quoted value    e.g.  path: 'src/hello.c'
//    • Input  — named-wire array         e.g.  input: ["hello.c": StaticFile(...).output]
//    • Output — output spec       e.g.  output -> ["result": StaticFile(...)]
//               (parsed and stored; not yet used in topology matching)
//
//  Each element inside an input/output array is a named wire entry:
//      "wireName": ShapeNode
//  Wire names correspond to Wire.name in the database and uniquely identify
//  each wire feeding a given port when multiple wires are present.
//
//  The trailing `.outputPort` suffix is optional:
//    • Present  → wire-endpoint form, used in spec strings
//    • Absent   → node-identity form, stored in Node.graphSpec
//
//
//  Examples:
//      StaticFile(path: 'src/hello.c').output
//      ClangPreprocessor(
//          configuration: ["config": Configuration(tool: 'preprocessor').output],
//          input: ["hello.c": StaticFile(path: 'hello.c').output]).output
//      ClangLinker(
//          objectFiles: ["compiler_hello": ClangCompiler(...).output,
//                        "compiler_main":  ClangCompiler(...).output]).output
//

import Foundation
import SemelNodeKit

// MARK: - Model

/// One init-time property that distinguishes a node from others of its type — `path` for a
/// StaticFile, `moduleName` for a compile.
///
/// Called a property, not an argument, because that is what a node calls it: these are
/// exactly a node's `properties`, rendered into a spec.
struct GraphSpecProperty: Equatable, Hashable {
    let key: String
    let value: String
}

/// A single named wire feeding an input port.
struct GraphSpecWire: Equatable {
    let name: String          // wire name, e.g. "src/hello.c"
    let node: GraphSpecNode  // the upstream node
}

/// A wired input port.  `wires` holds all named wires feeding this port.
struct GraphSpecInputPort: Equatable {
    let portName: String
    let wires:    [GraphSpecWire]
}

/// An expected output port entry (future use — parsed but not yet matched).
struct GraphSpecOutputPort: Equatable {
    let portName: String
    let wires:    [GraphSpecWire]
}

/// A node in the graph-spec tree.
public struct GraphSpecNode: Equatable {
    /// Swift type name of the Node, e.g. `"StaticFile"`, `"ClangCompiler"`.
    let typeName:   String
    /// Init-time key-value properties (e.g. `path: 'src/hello.c'`).  Ordered.
    let properties: [GraphSpecProperty]
    /// Wired input ports.  Ordered.
    let inputs:     [GraphSpecInputPort]
    /// Expected output ports (future use — stored but not yet matched).
    let outputs:    [GraphSpecOutputPort]
    /// Output port consumed downstream, or `nil` for the node-identity / graphSpec form.
    let outputPort: String?

    init(typeName:   String,
         properties: [GraphSpecProperty]   = [],
         inputs:     [GraphSpecInputPort]  = [],
         outputs:    [GraphSpecOutputPort] = [],
         outputPort: String?                = nil) {
        self.typeName   = typeName
        self.properties = properties
        self.inputs     = inputs
        self.outputs    = outputs
        self.outputPort = outputPort
    }
}

// MARK: - Serialisation

extension GraphSpecNode {

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

        // Properties: key: 'value' — always sorted so the string is deterministic
        // regardless of dictionary-iteration order or formula-file ordering.
        for property in properties.sorted(by: { $0.key < $1.key }) {
            params.append("\(property.key): '\(property.value)'")
        }

        // Inputs: portName: ["wireName": ShapeNode, ...]
        for input in inputs {
            let wireStrings = input.wires.map { wire in
                "\"\(wire.name)\": \(wire.node.asString(pretty: pretty, depth: depth + 1, omitOutputPort: false))"
            }
            let inner = pretty
                ? "\n\(indent)\(wireStrings.joined(separator: separator))\n\(String(repeating: "  ", count: depth))"
                : wireStrings.joined(separator: separator)
            params.append("\(input.portName): [\(inner)]")
        }

        // Outputs: portName -> ["wireName": ShapeNode, ...] (future use)
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

extension GraphSpecNode {

    enum TopologyMatchError: Error {
        case noMatch(reason: String)
    }

    func expectTopologyMatch(_ other: GraphSpecNode) throws {
        guard typeName == other.typeName else {
            throw TopologyMatchError.noMatch(reason: "Type name mismatch: \(typeName) != \(other.typeName)")
        }
        guard Set(properties) == Set(other.properties) else {
            throw TopologyMatchError.noMatch(reason: "Properties mismatch: \(properties) != \(other.properties)")
        }

        let selfPorts  = Dictionary(inputs.map       { ($0.portName, $0.wires) },
                                    uniquingKeysWith: { first, _ in first })

        let otherPorts = Dictionary(other.inputs.map { ($0.portName, $0.wires) },
                                    uniquingKeysWith: { first, _ in first })

        // Ports that are ONLY in `self` (current) are allowed to be extra — they are
        // dynamic ports added by the engine after node creation (e.g.
        // ClangPreprocessor's `includeFileLists` / `headerInputFiles`).
        //
        // For ports that appear in BOTH `self` and `other` (i.e. ports the formula
        // explicitly specifies), the wire sets must match exactly: same count and
        // same named wires.  A current port with MORE wires than expected means a
        // source file was removed and the node must be rewired, not reused.
        //
        // Within each port, wires are matched by name (not by position).
        // `database.wire.select` returns wires in insertion order, which can
        // differ from the order the formula string enumerates them, so a
        // positional zip would produce false mismatches.
        for (portName, otherWires) in otherPorts {
            guard let selfWires = selfPorts[portName] else {
                throw TopologyMatchError.noMatch(reason: "Expected port '\(portName)' is absent in the current graph spec")
            }
            guard selfWires.count == otherWires.count else {
                throw TopologyMatchError.noMatch(reason: "Wire count mismatch on port '\(portName)': current=\(selfWires.count), expected=\(otherWires.count)")
            }
            let selfWiresByName = Dictionary(selfWires.map { ($0.name, $0.node) },
                                             uniquingKeysWith: { first, _ in first })
            for otherWire in otherWires {
                guard let selfWireNode = selfWiresByName[otherWire.name] else {
                    throw TopologyMatchError.noMatch(reason: "Expected wire '\(otherWire.name)' on port '\(portName)' is absent in the current graph spec")
                }
                do {
                    try selfWireNode.expectTopologyMatch(otherWire.node)
                } catch let error as TopologyMatchError {
                    throw TopologyMatchError.noMatch(reason: "Child topology of wire '\(otherWire.name)' does not match for a \(selfWireNode.typeName): \(error)")
                }
            }
        }
    }
}

// MARK: - Parser

enum GraphSpecParseError: Error {
    case unexpectedCharacter(Character?, context: String)
    case unexpectedEndOfInput(context: String)
    case emptyIdentifier
}

extension GraphSpecNode {

    /// Parses a string produced by `asString()` back into a `GraphSpecNode`.
    public static func parse(_ string: String) throws -> GraphSpecNode {
        var parser = GraphSpecParser(string)
        return try parser.parseNode()
    }
}

// MARK: - Recursive-descent parser

private struct GraphSpecParser {

    private let chars: [Character]
    private var position: Int = 0

    init(_ string: String) { self.chars = Array(string) }

    // ── Entry ─────────────────────────────────────────────────────────────────

    mutating func parseNode() throws -> GraphSpecNode {
        skipWhitespace()
        let typeName = try parseIdentifier()
        try consume("(")
        skipWhitespace()

        var properties: [GraphSpecProperty]   = []
        var inputs:     [GraphSpecInputPort]  = []
        var outputs:    [GraphSpecOutputPort] = []

        if peek() != ")" {
            try parseParamList(properties: &properties, inputs: &inputs, outputs: &outputs)
        }
        skipWhitespace()
        try consume(")")

        let outputPort = try parseOptionalOutputPort()
        return GraphSpecNode(typeName:   typeName,
                              properties: properties,
                              inputs:     inputs,
                              outputs:    outputs,
                              outputPort: outputPort)
    }

    // ── Parameter list ────────────────────────────────────────────────────────

    mutating func parseParamList(properties: inout [GraphSpecProperty],
                                 inputs:     inout [GraphSpecInputPort],
                                 outputs:    inout [GraphSpecOutputPort]) throws {
        try parseOneParam(properties: &properties, inputs: &inputs, outputs: &outputs)
        while peek() == "," {
            advance()
            skipWhitespace()
            guard peek() != ")" else { break }
            try parseOneParam(properties: &properties, inputs: &inputs, outputs: &outputs)
        }
    }

    /// Parse one parameter.  Operator and value type determine kind:
    ///
    ///   `key: 'value'`              → property (quoted string after `:`)
    ///   `key.dotted: 'value'`       → property (dotted key, e.g. toolDescriptor.name)
    ///   `key: [...]`                → input (wire array after `:`)
    ///   `key -> [...]`              → output (future use)
    mutating func parseOneParam(properties: inout [GraphSpecProperty],
                                inputs:     inout [GraphSpecInputPort],
                                outputs:    inout [GraphSpecOutputPort]) throws {
        skipWhitespace()
        let key = try parseDottedKey()
        skipWhitespace()

        if peek() == ":" {
            advance()
            skipWhitespace()
            if peek() == "[" {
                // input wire port:  key: [...]
                let wires = try parseWireArray()
                inputs.append(GraphSpecInputPort(portName: key, wires: wires))
            } else {
                // property:  key: 'value'
                let value = try parseQuotedString()
                properties.append(GraphSpecProperty(key: key, value: value))
            }

        } else if peek() == "-" {
            // output:  key -> [...]
            advance()           // consume '-'
            try consume(">")   // consume '>'
            skipWhitespace()
            let wires = try parseWireArray()
            outputs.append(GraphSpecOutputPort(portName: key, wires: wires))

        } else {
            throw GraphSpecParseError.unexpectedCharacter(
                peek(), context: "expected ':' or '->' after key '\(key)'. Parsing: \(String(chars))")
        }
    }

    // ── Wire array: [ entry, entry, ... ] ────────────────────────────────────

    mutating func parseWireArray() throws -> [GraphSpecWire] {
        try consume("[")
        skipWhitespace()
        var wires: [GraphSpecWire] = []
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

    // ── Wire entry: "name": ShapeNode ─────────────────────────────────────────

    mutating func parseWireEntry() throws -> GraphSpecWire {
        skipWhitespace()
        let wireName = try parseQuotedString()
        skipWhitespace()
        try consume(":")
        skipWhitespace()
        let node = try parseNode()
        return GraphSpecWire(name: wireName, node: node)
    }

    // ── Quoted string (single or double quotes) ───────────────────────────────

    mutating func parseQuotedString() throws -> String {
        guard let quote = peek(), quote == "'" || quote == "\"" else {
            throw GraphSpecParseError.unexpectedCharacter(
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
        guard peek() == "." else {
            return nil
        }
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
            throw GraphSpecParseError.emptyIdentifier
        }
        return result
    }

    /// Like `parseIdentifier()` but also consumes `.`-separated segments,
    /// producing a dotted key such as `toolDescriptor.name`.  Used only for
    /// parameter keys, where a `.` is a key separator rather than an output-port
    /// suffix.
    mutating func parseDottedKey() throws -> String {
        var key = try parseIdentifier()
        while peek() == "." {
            let savedPos = position
            advance()   // consume '.'
            if let c = peek(), c.isLetter || c == "_" {
                key += "." + (try parseIdentifier())
            } else {
                position = savedPos   // not a dotted key — leave '.' for caller
                break
            }
        }
        return key
    }

    mutating func parseUntil(_ stop: Character) throws -> String {
        var result = ""
        while let c = peek(), c != stop { result.append(c); advance() }
        return result
    }

    mutating func consume(_ expected: Character) throws {
        guard let c = peek() else {
            throw GraphSpecParseError.unexpectedEndOfInput(
                context: "expected '\(expected)'. Parsing: \(String(chars))")
        }
        guard c == expected else {
            throw GraphSpecParseError.unexpectedCharacter(
                c, context: "expected '\(expected)'. Parsing: \(String(chars))")
        }
        advance()
    }

    mutating func skipWhitespace() { while let c = peek(), c.isWhitespace { advance() } }
    func     peek()    -> Character? { position < chars.count ? chars[position] : nil }
    mutating func advance() { position += 1 }
}
