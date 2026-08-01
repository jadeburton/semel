// FormulaParser.swift
// build_system
//
// Parser for the human-friendly .fmla formula format.
// Produces a [productName: GraphShapeNode] map compatible with the existing
// GraphShapeApplier find-or-create machinery.
//
// Grammar (informal):
//
//   formula     = topLevel*
//   topLevel    = funcDef | productDef
//   funcDef     = 'func' IDENT '(' paramList? ')' '=' expr
//   productDef  = 'product' (STRING | PATH) '=' expr
//   paramList   = IDENT (',' IDENT)*
//   expr        = STRING | PATH
//               | IDENT                                   -- parameter reference
//               | IDENT '(' argList? ')' ('.' IDENT)?    -- call or node construct
//   arg         = IDENT '<-' '[' wireEntry* ']'           -- input-wire port
//               | IDENT ':' expr                          -- labeled / property
//               | expr                                    -- positional
//   wireEntry   = (STRING | PATH) ':' expr (',' wireEntry)*
//   PATH        = '<' relativePath '>'
//
// PATH is resolved by the lexer: <rel/path> → basePath/rel/path, with '.' and
// '..' normalised.  It is an error for a PATH to escape basePath via '..'.
// The parser sees only STRING tokens, so PATH is valid everywhere STRING is.
//
// Disambiguation:  a call 'name(...)' resolves to a user-function call when
// 'name' appears in a 'func' definition; otherwise it is treated as a node
// construction.  This is decided during resolution, not parsing.

import Foundation

// MARK: - Public entry point

extension FormulaFile {

    /// Parse `source` (the text of a .fmla file) and resolve every `product`
    /// declaration to a `GraphShapeNode`.
    /// Returns a mapping of product name → node, ready for `GraphShapeApplier`.
    static func parse(_ source: String, basePath: Path) throws -> [String: GraphShapeNode] {
        let tokens = try FormulaLexer.tokenize(source, basePath: basePath)
        var parser = FormulaParser(tokens)
        let file   = try parser.parseFile()
        return try FormulaResolver(file).resolve()
    }
}

// MARK: - Formula AST

struct FormulaFile {
    let functions: [FuncDef]
    let products:  [ProductDef]
}

struct FuncDef {
    let name:   String
    let params: [String]
    let body:   FormulaExpr
}

struct ProductDef {
    let name: String   // e.g. "Package.json"
    let body: FormulaExpr
}

indirect enum FormulaExpr {
    case string(String)
    case identifier(String)   // parameter reference (no parentheses)
    case call(name: String, args: [FormulaCallArg], port: String?)
}

enum FormulaCallArg {
    case positional(FormulaExpr)
    case labeled(key: String, value: FormulaExpr)   // func named-arg OR node property
    case inputWire(portName: String, wires: [(name: String, value: FormulaExpr)])
}

// MARK: - Errors

enum FormulaParseError: Error, LocalizedError {
    case unexpectedToken(FormulaToken?, context: String)
    case undefinedIdentifier(String)
    case typeMismatch(expected: String, got: String, context: String)
    case wrongArgumentCount(function: String, expected: Int, got: Int)
    case positionalArgInNodeConstruction(typeName: String)
    case pathEscapesBasePath(path: String)

    var errorDescription: String? {
        switch self {
        case .unexpectedToken(let t, let ctx):
            return "Unexpected \(t.map { "\($0)" } ?? "end of input") — \(ctx)"
        case .undefinedIdentifier(let n):
            return "Undefined identifier '\(n)'"
        case .typeMismatch(let exp, let got, let ctx):
            return "Type mismatch: expected \(exp), got \(got) — \(ctx)"
        case .wrongArgumentCount(let f, let exp, let got):
            return "Wrong argument count for '\(f)': expected \(exp), got \(got)"
        case .positionalArgInNodeConstruction(let t):
            return "Positional argument in node construction '\(t)': use 'key: value' or 'port <- [...]'"
        case .pathEscapesBasePath(let p):
            return "Path literal '<\(p)>' escapes the formula base path"
        }
    }
}

// MARK: - Tokens

enum FormulaToken: Equatable, CustomStringConvertible {
    case kwFunc, kwProduct
    case lparen, rparen
    case lbracket, rbracket
    case comma, colon, equals, dot
    case arrow           // <-
    case ident(String)
    case string(String)
    case eof

    var description: String {
        switch self {
        case .kwFunc:        return "'func'"
        case .kwProduct:     return "'product'"
        case .lparen:        return "'('"
        case .rparen:        return "')'"
        case .lbracket:      return "'['"
        case .rbracket:      return "']'"
        case .comma:         return "','"
        case .colon:         return "':'"
        case .equals:        return "'='"
        case .dot:           return "'.'"
        case .arrow:         return "'<-'"
        case .ident(let s):  return "identifier '\(s)'"
        case .string(let s): return "string '\(s)'"
        case .eof:           return "end of input"
        }
    }
}

// MARK: - Lexer

enum FormulaLexer {
    static func tokenize(_ source: String, basePath: Path) throws -> [FormulaToken] {
        var tokens: [FormulaToken] = []
        let chars = Array(source)
        var i = 0

        while i < chars.count {
            let c = chars[i]

            // Whitespace
            if c.isWhitespace { i += 1; continue }

            // // line comment — skip to end of line
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "/" {
                while i < chars.count && chars[i] != "\n" { i += 1 }
                continue
            }

            // String literals (single or double quoted)
            if c == "'" || c == "\"" {
                let q = c; i += 1
                var s = ""
                while i < chars.count && chars[i] != q { s.append(chars[i]); i += 1 }
                guard i < chars.count else {
                    throw FormulaParseError.unexpectedToken(nil, context: "unterminated string literal")
                }
                i += 1   // closing quote
                tokens.append(.string(s))
                continue
            }

            // <- arrow (must check before path literal handling of '<')
            if c == "<" && i + 1 < chars.count && chars[i + 1] == "-" {
                i += 2; tokens.append(.arrow); continue
            }

            // Angle-bracket path literal  <rel/path>  — resolved against basePath
            if c == "<" {
                i += 1   // consume '<'
                var raw = ""
                while i < chars.count && chars[i] != ">" { raw.append(chars[i]); i += 1 }
                guard i < chars.count else {
                    throw FormulaParseError.unexpectedToken(nil, context: "unterminated path literal '<\(raw)'")
                }
                i += 1   // consume '>'
                tokens.append(.string(try resolvePathLiteral(raw, relativeTo: basePath)))
                continue
            }

            // Single-character tokens
            switch c {
            case "(": tokens.append(.lparen);   i += 1
            case ")": tokens.append(.rparen);   i += 1
            case "[": tokens.append(.lbracket); i += 1
            case "]": tokens.append(.rbracket); i += 1
            case ",": tokens.append(.comma);    i += 1
            case ":": tokens.append(.colon);    i += 1
            case "=": tokens.append(.equals);   i += 1
            case ".": tokens.append(.dot);      i += 1
            default:
                if c.isLetter || c == "_" {
                    var s = ""
                    while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                        s.append(chars[i]); i += 1
                    }
                    switch s {
                    case "func":    tokens.append(.kwFunc)
                    case "product": tokens.append(.kwProduct)
                    default:        tokens.append(.ident(s))
                    }
                } else {
                    throw FormulaParseError.unexpectedToken(nil, context: "unexpected character '\(c)'")
                }
            }
        }

        tokens.append(.eof)
        return tokens
    }

    // Resolves a relative path against basePath, normalising '.' and '..',
    // and errors if the result would escape basePath.
    private static func resolvePathLiteral(_ raw: String, relativeTo basePath: Path) throws -> String {
        // Normalise basePath into components.
        var baseComponents: [String] = []
        for part in basePath.string.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            switch part {
            case ".":  break
            case "..": if !baseComponents.isEmpty { baseComponents.removeLast() }
            default:   baseComponents.append(part)
            }
        }

        // Walk the relative path starting from basePath, never going above it.
        var components = baseComponents
        let baseDepth  = baseComponents.count

        for part in raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            switch part {
            case ".":  break
            case "..":
                guard components.count > baseDepth else {
                    throw FormulaParseError.pathEscapesBasePath(path: raw)
                }
                components.removeLast()
            default:
                components.append(part)
            }
        }

        return components.joined(separator: "/")
    }
}

// MARK: - Parser

private struct FormulaParser {
    private let tokens: [FormulaToken]
    private var pos = 0

    init(_ tokens: [FormulaToken]) { self.tokens = tokens }

    private var current: FormulaToken { tokens[pos] }
    private var peek1:   FormulaToken { pos + 1 < tokens.count ? tokens[pos + 1] : .eof }

    private mutating func advance() { if pos < tokens.count - 1 { pos += 1 } }

    private mutating func expect(_ t: FormulaToken) throws {
        guard current == t else {
            throw FormulaParseError.unexpectedToken(current, context: "expected \(t)")
        }
        advance()
    }

    // MARK: Top level

    mutating func parseFile() throws -> FormulaFile {
        var functions: [FuncDef]    = []
        var products:  [ProductDef] = []

        while current != .eof {
            switch current {
            case .kwFunc:
                functions.append(try parseFuncDef())
            case .kwProduct:
                products.append(try parseProductDef())
            default:
                throw FormulaParseError.unexpectedToken(current, context: "expected 'func' or 'product'")
            }
        }

        return FormulaFile(functions: functions, products: products)
    }

    // func name(p1, p2, ...) = expr
    private mutating func parseFuncDef() throws -> FuncDef {
        try expect(.kwFunc)
        guard case .ident(let name) = current else {
            throw FormulaParseError.unexpectedToken(current, context: "expected function name after 'func'")
        }
        advance()
        try expect(.lparen)
        var params: [String] = []
        while current != .rparen {
            guard case .ident(let p) = current else {
                throw FormulaParseError.unexpectedToken(current, context: "expected parameter name")
            }
            params.append(p); advance()
            if current == .comma { advance() }
        }
        try expect(.rparen)
        try expect(.equals)
        return FuncDef(name: name, params: params, body: try parseExpr())
    }

    // product "name" = expr
    private mutating func parseProductDef() throws -> ProductDef {
        try expect(.kwProduct)
        guard case .string(let name) = current else {
            throw FormulaParseError.unexpectedToken(current, context: "expected product name string after 'product'")
        }
        advance()
        try expect(.equals)
        return ProductDef(name: name, body: try parseExpr())
    }

    // MARK: Expressions

    // expr = STRING
    //      | IDENT                               -- parameter reference
    //      | IDENT '(' argList? ')' ('.' IDENT)? -- call / node construct
    private mutating func parseExpr() throws -> FormulaExpr {
        switch current {
        case .string(let s):
            advance()
            return .string(s)
        case .ident(let name):
            advance()
            guard current == .lparen else {
                return .identifier(name)   // no parens → parameter reference
            }
            advance()   // consume '('
            let args = current == .rparen ? [] : try parseArgList()
            try expect(.rparen)
            let port = try parseOptionalPort()
            return .call(name: name, args: args, port: port)
        default:
            throw FormulaParseError.unexpectedToken(current, context: "expected expression")
        }
    }

    private mutating func parseArgList() throws -> [FormulaCallArg] {
        var args: [FormulaCallArg] = []
        args.append(try parseArg())
        while current == .comma {
            advance()
            if current == .rparen { break }   // trailing comma
            args.append(try parseArg())
        }
        return args
    }

    // arg = IDENT '<-' '[' wireDict ']'   -- input-wire port
    //     | IDENT ':' expr                -- labeled arg or node property
    //     | expr                          -- positional
    //
    // Two-token lookahead (current + peek1) disambiguates the first two forms.
    private mutating func parseArg() throws -> FormulaCallArg {
        if case .ident(let name) = current {
            if peek1 == .arrow {
                advance(); advance()   // consume IDENT and <-
                return .inputWire(portName: name, wires: try parseWireDict())
            }
            if peek1 == .colon {
                advance(); advance()   // consume IDENT and :
                return .labeled(key: name, value: try parseExpr())
            }
        }
        return .positional(try parseExpr())
    }

    // '[' (STRING ':' expr (',' STRING ':' expr)*)? ']'
    private mutating func parseWireDict() throws -> [(name: String, value: FormulaExpr)] {
        try expect(.lbracket)
        var wires: [(String, FormulaExpr)] = []
        while current != .rbracket {
            guard case .string(let name) = current else {
                throw FormulaParseError.unexpectedToken(current, context: "expected wire name string in wire dict")
            }
            advance()
            try expect(.colon)
            wires.append((name, try parseExpr()))
            if current == .comma { advance() }
        }
        try expect(.rbracket)
        return wires
    }

    // ('.' IDENT)?
    private mutating func parseOptionalPort() throws -> String? {
        guard current == .dot else { return nil }
        advance()
        guard case .ident(let port) = current else {
            throw FormulaParseError.unexpectedToken(current, context: "expected port name after '.'")
        }
        advance()
        return port
    }
}

// MARK: - Resolver

private enum FormulaValue {
    case node(GraphShapeNode)
    case string(String)

    var typeName: String { switch self { case .node: return "node"; case .string: return "string" } }
}

private struct FormulaResolver {
    let functions: [String: FuncDef]
    let products:  [ProductDef]

    init(_ file: FormulaFile) {
        functions = Dictionary(uniqueKeysWithValues: file.functions.map { ($0.name, $0) })
        products  = file.products
    }

    func resolve() throws -> [String: GraphShapeNode] {
        var result: [String: GraphShapeNode] = [:]
        for product in products {
            let value = try eval(product.body, env: [:])
            guard case .node(let node) = value else {
                throw FormulaParseError.typeMismatch(
                    expected: "node", got: value.typeName,
                    context: "product '\(product.name)' must resolve to a node")
            }
            result[product.name] = node
        }
        return result
    }

    // MARK: Evaluation

    func eval(_ expr: FormulaExpr, env: [String: FormulaValue]) throws -> FormulaValue {
        switch expr {

        case .string(let s):
            return .string(s)

        case .identifier(let name):
            // Parameter reference — must be bound in the current environment.
            // (Note: the global function 'name' is shadowed by a same-named parameter.)
            guard let value = env[name] else {
                throw FormulaParseError.undefinedIdentifier(name)
            }
            return value

        case .call(let name, let args, let port):
            let base: FormulaValue
            if let funcDef = functions[name] {
                base = try evalFuncCall(funcDef, args: args, env: env)
            } else {
                base = try evalNodeConstruct(typeName: name, args: args, env: env)
            }
            guard let port else { return base }
            // Apply trailing .portName
            guard case .node(let node) = base else {
                throw FormulaParseError.typeMismatch(
                    expected: "node (for port access '.\(port)')", got: base.typeName,
                    context: "cannot access an output port on a string value")
            }
            return .node(GraphShapeNode(typeName: node.typeName,
                                         args:    node.args,
                                         inputs:  node.inputs,
                                         outputs: node.outputs,
                                         outputPort: port))
        }
    }

    // User-defined function call: bind args to params then evaluate body.
    func evalFuncCall(_ funcDef: FuncDef, args: [FormulaCallArg], env: [String: FormulaValue]) throws -> FormulaValue {
        var newEnv = env
        var positionalIdx = 0

        for arg in args {
            switch arg {
            case .positional(let expr):
                guard positionalIdx < funcDef.params.count else {
                    throw FormulaParseError.wrongArgumentCount(
                        function: funcDef.name, expected: funcDef.params.count, got: positionalIdx + 1)
                }
                newEnv[funcDef.params[positionalIdx]] = try eval(expr, env: env)
                positionalIdx += 1

            case .labeled(let key, let expr):
                guard funcDef.params.contains(key) else {
                    throw FormulaParseError.undefinedIdentifier(
                        "parameter '\(key)' in function '\(funcDef.name)'")
                }
                newEnv[key] = try eval(expr, env: env)

            case .inputWire:
                throw FormulaParseError.typeMismatch(
                    expected: "value argument", got: "wire expression '<-'",
                    context: "wire syntax is not valid when calling function '\(funcDef.name)'")
            }
        }

        return try eval(funcDef.body, env: newEnv)
    }

    // Node construction: map labeled args → GraphShapeArg, wires → GraphShapeInputPort.
    func evalNodeConstruct(typeName: String, args: [FormulaCallArg], env: [String: FormulaValue]) throws -> FormulaValue {
        var nodeArgs:   [GraphShapeArg]       = []
        var inputPorts: [GraphShapeInputPort] = []

        for arg in args {
            switch arg {
            case .labeled(let key, let expr):
                let value = try eval(expr, env: env)
                guard case .string(let s) = value else {
                    throw FormulaParseError.typeMismatch(
                        expected: "string (property '\(key)' of '\(typeName)')",
                        got: value.typeName,
                        context: "node property values must be string expressions")
                }
                nodeArgs.append(GraphShapeArg(key: key, value: s))

            case .inputWire(let portName, let wires):
                var graphWires: [GraphShapeWire] = []
                for (wireName, wireExpr) in wires {
                    let value = try eval(wireExpr, env: env)
                    guard case .node(let node) = value else {
                        throw FormulaParseError.typeMismatch(
                            expected: "node (wire '\(wireName)' on port '\(portName)' of '\(typeName)')",
                            got: value.typeName,
                            context: "wire values must be node expressions")
                    }
                    graphWires.append(GraphShapeWire(name: wireName, node: node))
                }
                inputPorts.append(GraphShapeInputPort(portName: portName, wires: graphWires))

            case .positional:
                throw FormulaParseError.positionalArgInNodeConstruction(typeName: typeName)
            }
        }

        return .node(GraphShapeNode(typeName: typeName, args: nodeArgs, inputs: inputPorts))
    }
}
