// FormulaParser.swift
// semel
//
// Parser for the human-friendly .fmla formula format.
// Produces a [productName: GraphSpecNode] map compatible with the existing
// GraphSpecApplier find-or-create machinery.
//
// Grammar (informal):
//
//   formula     = ('namespace' IDENT)? topLevel*          -- 'namespace' only in a prelude
//   topLevel    = funcDef | productDef | include
//   funcDef     = 'func' IDENT '(' paramList? ')' '=' expr
//   productDef  = 'product' (STRING | PATH) '=' expr
//   include     = 'include' 'funcs'? expr                 -- a node's formula text, or a
//                                                         -- STRING naming a plugin's prelude;
//                                                         -- 'funcs' brings its funcs, not its products
//   paramList   = IDENT (',' IDENT)*
//   expr        = STRING | PATH
//               | IDENT                                   -- parameter reference
//               | IDENT '(' argList? ')' ('.' IDENT)?    -- call or node construct
//               | IDENT '.' IDENT '(' argList? ')' ('.' IDENT)?   -- a prelude's func
//   arg         = IDENT ':' '[' wireEntry* ']'            -- input-wire port (value is a wire dict)
//               | IDENT ':' expr                          -- labeled / property
//               | expr                                    -- positional
//   wireEntry   = forEachPrefix? (STRING | PATH) ':' expr (',' wireEntry)*
//   forEachPrefix = '{' IDENT ':' forEachItems ('except' forEachItems)? '}'
//   forEachItems = forEachItem (',' forEachItem)*
//   forEachItem = STRING | PATH | IDENT                   -- literal, wildcard pattern or parameter
//   PATH        = '<' relativePath '>'
//
// PATH is resolved by the lexer: <rel/path> → basePath/rel/path, with '.' and
// '..' normalised.  It is an error for a PATH to escape basePath via '..'.
// EXCEPTION: if the path content contains '%%', it is a template expression —
// the static prefix (before the first '%%') is resolved against basePath, then
// the '%%marker%%' portion is appended verbatim so %%var%% substitution can
// occur at evaluation time.
// The parser sees only STRING tokens, so PATH is valid everywhere STRING is.
//
// For-each expansion:
//   {var: 'a', 'b'} "%%var%%": NodeType(param: "%%var%%")
// expands to two wire entries with var='a' and var='b' substituted.
// Glob patterns in for-each items (e.g. <src/*.c>) are expanded via the
// wildcardExpander callback passed to FormulaFile.parse.
//   {f: <*.c> except <main.c>, <test_*.c>} "%%f%%.o": …
// expands both lists and iterates the first less every path the second matched.
// 'except' is a keyword only there — after an item and before another — so a func,
// parameter or wire named 'except' is still a name everywhere else.
//
// %%var%%    — full value of var
// %%var.N%%  — Nth wildcard capture group (0-based) from a wildcard pattern
// %%var.folder%% — containing directory path with trailing slash
//
// Disambiguation:  a call 'name(...)' resolves to a user-function call when
// 'name' appears in a 'func' definition; otherwise it is treated as a node
// construction.  This is decided during resolution, not parsing.

import Foundation
import SemelNodeKit

// MARK: - Public entry point

extension FormulaFile {

    /// Parse `source` (the text of a .fmla file) and resolve every `product`
    /// declaration to a `GraphSpecNode`.
    /// `wildcardExpander` is called for any for-each items that contain wildcards
    /// ('*' or '?'); it should return the sorted list of matching logical paths.
    /// `fileReader` is called for every `import(path:)` expression; it should
    /// return the file contents, or `nil` if the file is not yet available (which
    /// causes the resolver to substitute a placeholder node so that dependency
    /// discovery continues — the caller is responsible for checking whether any
    /// import was unavailable before using the returned products).
    /// `includeReader` is called with the rendered spec of the node each `include <expr>`
    /// statement names; it should return the formula text that node produced, or `nil` if
    /// it is not yet available — in which case nothing can be resolved (the file's own
    /// products may call the included formula's funcs) and the result is empty. The caller
    /// records the spec in the same call, so it can wire the node and try again.
    /// Returns a mapping of product name → node, ready for `GraphSpecApplier`.
    static func parse(
        _ source: String,
        basePath: Path,
        wildcardExpander: @escaping (String) throws -> [String],
        fileReader: @escaping (String) throws -> String? = { _ in nil },
        includeReader: @escaping (GraphSpecNode) throws -> String? = { _ in nil }
    ) throws -> [String: GraphSpecNode] {
        let tokens = try FormulaLexer.tokenize(source, basePath: basePath)
        var parser = FormulaParser(tokens)
        var file   = try parser.parseFile()
        if let namespace = file.namespace {
            throw FormulaParseError.namespaceOutsidePrelude(namespace: namespace)
        }

        // An include expression may call the file's own funcs, so it is resolved against
        // them — before the included text is merged in, which is what keeps the direction
        // of definition one way. An included text may include in turn — a project's
        // generated formula includes each package's — so includes are followed to the
        // end, each spec once: two texts that include the same package name one node.
        //
        // Whatever is reached through `include funcs` brings its funcs and not its
        // products, its own includes too. A spec reached both ways brings its products:
        // one path asking for them is enough, so a spec first merged for its funcs alone
        // is merged again, whole, when a full include reaches it.
        //
        // Each text sees the namespaces it includes itself, and no other (B-111): a prelude
        // pulled in by another prelude is callable inside that prelude, and from the
        // formula only once the formula includes it too. A scope is a prelude's namespace,
        // or `nil` for the formula; an unnamespaced text — a package's generated formula —
        // is merged into its includer's scope, so what it includes, its includer sees.
        let own = FormulaResolver(file, wildcardExpander: wildcardExpander, fileReader: fileReader)
        var pending = file.includes.map { (include: $0, scope: String?.none) }
        var broughtProducts: [String: Bool] = [:]
        var namespaceOfSpec: [String: String?] = [:]
        var visible: [String?: Set<String>] = [:]
        while !pending.isEmpty {
            let (include, scope) = pending.removeFirst()
            let includedNode = try own.resolve(include: include.expr)
            let spec = includedNode.asString(omitOutputPort: false)
            if let brought = broughtProducts[spec], brought || include.funcsOnly {
                // Merged already, but this includer sees it too.
                if let namespace = namespaceOfSpec[spec] ?? nil {
                    visible[scope, default: []].insert(namespace)
                }
                continue
            }
            broughtProducts[spec] = !include.funcsOnly
            guard let includedFormula = try includeReader(includedNode) else {
                return [:]
            }
            // Generated text names every path absolutely, so the base path is nominal.
            var includedParser = FormulaParser(try FormulaLexer.tokenize(includedFormula, basePath: basePath))
            let parsed = try includedParser.parseFile()
            let includedFile = try parsed.namespaced()
            namespaceOfSpec[spec] = parsed.namespace
            if let namespace = parsed.namespace {
                visible[scope, default: []].insert(namespace)
            }
            file = try file.merging(include.funcsOnly ? includedFile.withoutProducts() : includedFile)
            pending += includedFile.includes.map {
                (FormulaInclude(expr: $0.expr, funcsOnly: $0.funcsOnly || include.funcsOnly), parsed.namespace ?? scope)
            }
        }
        try file.checkNamespaceVisibility(visible)

        return try FormulaResolver(file, wildcardExpander: wildcardExpander, fileReader: fileReader).resolve()
    }
}

// MARK: - Formula AST

/// One `include` statement. `include funcs <expr>` brings the included text's funcs and
/// leaves its products out: an app includes a package's formula to link its modules and
/// objects, and the package's own archives are not the app's products (B-67).
struct FormulaInclude {
    let expr:      FormulaExpr
    let funcsOnly: Bool
}

struct FormulaFile {
    let functions: [FuncDef]
    let products:  [ProductDef]
    /// `include <expr>` statements: each names a node whose output is formula text — a
    /// Swift package's generated formula, from `SwiftFormulaConverter(path: <.>).formula`.
    /// That text is merged into this file before resolution, so its products are this
    /// file's products and its funcs are callable. The language knows nothing about
    /// packages or toolchains here: it merges what the named node produces.
    let includes:  [FormulaInclude]
    /// `namespace <name>`: set on a plugin's prelude (B-108), whose funcs a formula calls as
    /// `name.func(…)`. `FormulaPrelude` writes the line; a formula of its own may not.
    var namespace: String?

    /// A prelude's funcs under its namespace: each `f` becomes `namespace.f`, and so does
    /// every call the prelude makes to one of its own funcs. A plain file is returned as it
    /// is.
    ///
    /// Renaming here rather than scoping in the resolver keeps resolution a lookup by name:
    /// `clang.executable` is simply the name of a func. A prelude's calls to its siblings are
    /// renamed with it, so its text reads as a formula would — `objects(…)`, not
    /// `clang.objects(…)` — while a call into another prelude it includes keeps that
    /// prelude's namespace.
    func namespaced() throws -> FormulaFile {
        guard let namespace else {
            return self
        }
        if let product = products.first {
            throw FormulaParseError.productInPrelude(namespace: namespace, product: product.name)
        }
        let ownNames = Set(functions.map(\.name))
        let renamed = functions.map { function in
            FuncDef(name:   "\(namespace).\(function.name)",
                    params: function.params,
                    body:   function.body.renamingCalls(to: ownNames, under: namespace))
        }
        return FormulaFile(functions: renamed, products: [], includes: includes)
    }

    /// This file's funcs and includes, without its products: what `include funcs` merges.
    func withoutProducts() -> FormulaFile {
        FormulaFile(functions: functions, products: [], includes: includes, namespace: namespace)
    }

    /// This file with `other`'s functions and products added.
    ///
    /// A name defined by both with the *same* definition is one definition: several
    /// included formulas that reach the same dependency package each carry its generated
    /// funcs, identically, and they resolve to the same nodes. A name defined by both
    /// *differently* is an error rather than a silent override — the resolver keys
    /// functions by name, and the formula author has no way to see the generated names
    /// they might shadow.
    func merging(_ other: FormulaFile) throws -> FormulaFile {
        let ownFunctions = Dictionary(functions.map { ($0.name, $0) }) { first, _ in first }
        var mergedFunctions = functions
        for function in other.functions {
            guard let existing = ownFunctions[function.name] else {
                mergedFunctions.append(function)
                continue
            }
            guard existing == function else {
                throw FormulaParseError.duplicateDefinition(kind: "func", name: function.name)
            }
        }

        let ownProducts = Dictionary(products.map { ($0.name, $0) }) { first, _ in first }
        var mergedProducts = products
        for product in other.products {
            guard let existing = ownProducts[product.name] else {
                mergedProducts.append(product)
                continue
            }
            guard existing == product else {
                throw FormulaParseError.duplicateDefinition(kind: "product", name: product.name)
            }
        }

        return FormulaFile(functions: mergedFunctions, products: mergedProducts, includes: includes)
    }

    /// Every dotted call names a namespace its caller may see (B-111): the caller's own,
    /// or one the caller's text includes itself. `visible` maps a scope — a prelude's
    /// namespace, `nil` for the formula — to the namespaces it includes. A func's scope is
    /// the namespace in its name, since `namespaced()` put it there; a product's is the
    /// formula's. Checked once, after merging, as a walk over the text: resolution stays a
    /// lookup by name.
    func checkNamespaceVisibility(_ visible: [String?: Set<String>]) throws {
        for function in functions {
            try Self.checkCalls(in: function.body, from: Self.namespace(ofName: function.name), visible: visible)
        }
        for product in products {
            try Self.checkCalls(in: product.body, from: nil, visible: visible)
        }
    }

    /// The namespace of a dotted name, `clang` in `clang.executable`; nil for a bare one.
    private static func namespace(ofName name: String) -> String? {
        guard let dot = name.firstIndex(of: ".") else {
            return nil
        }
        return String(name[..<dot])
    }

    private static func checkCalls(in body: FormulaExpr, from scope: String?, visible: [String?: Set<String>]) throws {
        for callee in body.callNames {
            guard let namespace = namespace(ofName: callee), namespace != scope,
                  !(visible[scope] ?? []).contains(namespace) else {
                continue
            }
            throw FormulaParseError.preludeNotIncluded(namespace: namespace, callee: callee, scope: scope)
        }
    }
}

struct FuncDef: Equatable {
    let name:   String
    let params: [String]
    let body:   FormulaExpr
}

struct ProductDef: Equatable {
    let name: String   // e.g. "Package.json"
    let body: FormulaExpr
}

indirect enum FormulaExpr: Equatable {
    case string(String)
    case identifier(String)   // parameter reference (no parentheses)
    case call(name: String, args: [FormulaCallArg], port: String?)
}

enum FormulaCallArg: Equatable {
    case positional(FormulaExpr)
    case labeled(key: String, value: FormulaExpr)    // func named-arg OR node property
    case inputWire(portName: String, wires: [WireDictEntry])
}

// MARK: - The calls an expression makes

extension FormulaExpr {
    /// The name of every call in this expression, outermost first.
    var callNames: [String] {
        guard case .call(let name, let args, _) = self else {
            return []
        }
        return [name] + args.flatMap(\.callNames)
    }
}

extension FormulaCallArg {
    var callNames: [String] {
        switch self {
        case .positional(let expr):        return expr.callNames
        case .labeled(_, let expr):        return expr.callNames
        case .inputWire(_, let wires):     return wires.flatMap(\.callNames)
        }
    }
}

extension WireDictEntry {
    var callNames: [String] {
        switch self {
        case .simple(let key, let value):            return key.callNames + value.callNames
        case .unnamed(let value):                    return value.callNames
        case .forEach(_, let items, let excluded, _, let value):
            return items.flatMap(\.callNames) + excluded.flatMap(\.callNames) + value.callNames
        }
    }
}

// MARK: - Namespacing a prelude's calls

extension FormulaExpr {
    /// This expression with every call to one of `names` spelled `namespace.name`.
    func renamingCalls(to names: Set<String>, under namespace: String) -> FormulaExpr {
        guard case .call(let name, let args, let port) = self else {
            return self
        }
        let callee = names.contains(name) ? "\(namespace).\(name)" : name
        return .call(name: callee, args: args.map { $0.renamingCalls(to: names, under: namespace) }, port: port)
    }
}

extension FormulaCallArg {
    func renamingCalls(to names: Set<String>, under namespace: String) -> FormulaCallArg {
        switch self {
        case .positional(let expr):
            return .positional(expr.renamingCalls(to: names, under: namespace))
        case .labeled(let key, let expr):
            return .labeled(key: key, value: expr.renamingCalls(to: names, under: namespace))
        case .inputWire(let portName, let wires):
            return .inputWire(portName: portName, wires: wires.map { $0.renamingCalls(to: names, under: namespace) })
        }
    }
}

extension WireDictEntry {
    func renamingCalls(to names: Set<String>, under namespace: String) -> WireDictEntry {
        switch self {
        case .simple(let key, let value):
            return .simple(key:   key.renamingCalls(to: names, under: namespace),
                           value: value.renamingCalls(to: names, under: namespace))
        case .unnamed(let value):
            return .unnamed(value: value.renamingCalls(to: names, under: namespace))
        case .forEach(let variable, let items, let excluded, let key, let value):
            return .forEach(variable: variable,
                            items:    items.map    { $0.renamingCalls(to: names, under: namespace) },
                            excluded: excluded.map { $0.renamingCalls(to: names, under: namespace) },
                            key:      key,
                            value:    value.renamingCalls(to: names, under: namespace))
        }
    }
}

/// A single entry in an input-wire dictionary.
///
/// A `simple` entry contributes exactly one wire with an explicit key.
/// An `unnamed` entry contributes one wire whose name is auto-generated
/// as `"wire0"`, `"wire1"`, … based on its position in the port's wire list.
/// A `forEach` entry contributes one wire per item (after wildcard expansion) that no
/// `excluded` item names, with `%%variable%%` substituted into the key template and every
/// string literal.
enum WireDictEntry: Equatable {
    case simple(key: FormulaExpr, value: FormulaExpr)
    case unnamed(value: FormulaExpr)
    case forEach(variable: String, items: [FormulaExpr], excluded: [FormulaExpr], key: String, value: FormulaExpr)
    // simple.key: any expression that resolves to a String (literal, identifier, or template)
    // forEach.key: template string — may contain %%variable%%
    // items: string expressions or parameter references — evaluated then wildcard-expanded if they contain wildcards
    // excluded: the items after 'except', evaluated and expanded the same way; empty when there is no 'except'
}

// MARK: - Errors

/// A formula the user wrote by hand rejected, in words.
///
/// Both protocols, for one sentence: the engine interns a thrown error's text by
/// interpolating it, which asks for `CustomStringConvertible` and never reaches
/// `errorDescription` — that answers `localizedDescription` alone.
enum FormulaParseError: Error, LocalizedError, CustomStringConvertible {
    case unexpectedToken(FormulaToken, expected: String)
    case unexpectedCharacter(Character, context: String)
    case unterminatedLiteralString(context: String)
    case unterminatedPathLiteral(context: String)
    case undefinedIdentifier(String)
    case typeMismatch(expected: String, got: String, context: String)
    case wrongArgumentCount(function: String, expected: Int, got: Int)
    case positionalArgInNodeConstruction(typeName: String)
    case pathEscapesBasePath(path: String)
    case pathEscapesRoot(path: String)
    case forEachRequiresAtLeastOneItem
    case forEachExceptLeavesNothing(variable: String, removed: [String])
    case duplicateDefinition(kind: String, name: String)
    case unboundParameter(function: String, parameter: String)
    case namespaceOutsidePrelude(namespace: String)
    case productInPrelude(namespace: String, product: String)
    case preludeNotIncluded(namespace: String, callee: String, scope: String?)

    var description: String {
        switch self {
        case .unexpectedToken(let token, let expected):
            return "Unexpected token: \(token) — expected: \(expected)"
        case .unexpectedCharacter(let c, let ctx):
            return "Unexpected character: \(c) — \(ctx)"
        case .unterminatedLiteralString(let ctx):
            return "Unterminated literal string — \(ctx)"
        case .unterminatedPathLiteral(let ctx):
            return "Unterminated path literal — \(ctx)"
        case .undefinedIdentifier(let n):
            return "Undefined identifier '\(n)'"
        case .typeMismatch(let exp, let got, let ctx):
            return "Type mismatch: expected \(exp), got \(got) — \(ctx)"
        case .wrongArgumentCount(let f, let exp, let got):
            return "Wrong argument count for '\(f)': expected \(exp), got \(got)"
        case .positionalArgInNodeConstruction(let t):
            return "Positional argument in node construction '\(t)': use 'key: value' or 'port: [...]'"
        case .pathEscapesBasePath(let p):
            return "Path literal '<\(p)>' escapes the formula base path"
        case .pathEscapesRoot(let p):
            return "Path literal '<\(p)>' escapes the root path"
        case .forEachRequiresAtLeastOneItem:
            return "for-each '{...}' requires at least one item"
        case .forEachExceptLeavesNothing(let variable, let removed):
            return "for-each '{\(variable): ...}' leaves nothing: its 'except' removes every item it matched ("
                 + removed.joined(separator: ", ") + ")"
        case .duplicateDefinition(let kind, let name):
            return "\(kind) '\(name)' is defined both by the formula and by a formula it includes"
        case .unboundParameter(let function, let parameter):
            return "'\(function)' is called without its parameter '\(parameter)'"
        case .namespaceOutsidePrelude(let namespace):
            return "'namespace \(namespace)' belongs to a plugin's prelude, not to a formula"
        case .productInPrelude(let namespace, let product):
            return "the prelude '\(namespace)' declares the product '\(product)'; a prelude holds funcs only"
        case .preludeNotIncluded(let namespace, let callee, let scope):
            guard let scope else {
                return "'\(callee)' calls into the prelude '\(namespace)', which this formula does not include; "
                     + "add the include that provides it"
            }
            return "the prelude '\(scope)' calls '\(callee)' without including the prelude that provides '\(namespace)'"
        }
    }

    /// The same sentence through `LocalizedError`, for a caller that asks that way.
    var errorDescription: String? {
        description
    }
}

/// A `FormulaParseError` enriched with the source location where the problem occurred.
/// Produced by the lexer for character-level failures (unrecognised character, unterminated
/// literal).  Its `CustomStringConvertible` produces a multi-line human-readable string
/// that is stored verbatim in the node's error output port and shown by the `errors` command.
struct FormulaLexerError: Error, CustomStringConvertible {
    let underlying: FormulaParseError
    let line: Int       // 1-based
    let column: Int     // 1-based
    let lineText: String

    var description: String {
        let detail = underlying.errorDescription ?? "\(underlying)"
        var msg = "line \(line), col \(column): \(detail)"
        if !lineText.isEmpty { msg += "\n\(lineText)" }
        return msg
    }
}

// MARK: - Tokens

enum FormulaToken: Equatable, CustomStringConvertible {
    case kwFunc, kwProduct, kwInclude
    case lparen, rparen
    case lbracket, rbracket
    case lbrace, rbrace
    case comma, colon, equals, dot
    case ident(String)
    case string(String)
    case eof

    var description: String {
        switch self {
        case .kwFunc:        return "'func'"
        case .kwProduct:     return "'product'"
        case .kwInclude:     return "'include'"
        case .lparen:        return "'('"
        case .rparen:        return "')'"
        case .lbracket:      return "'['"
        case .rbracket:      return "']'"
        case .lbrace:        return "'{'"
        case .rbrace:        return "'}'"
        case .comma:         return "','"
        case .colon:         return "':'"
        case .equals:        return "'='"
        case .dot:           return "'.'"
        case .ident(let s):  return "identifier '\(s)'"
        case .string(let s): return "string '\(s)'"
        case .eof:           return "end of input"
        }
    }
}

/// A lexed token together with its source location, used by `FormulaParser`
/// to attach position info to every parse error.
fileprivate struct TokenWithLocation {
    let token:    FormulaToken
    let line:     Int     // 1-based
    let col:      Int     // 1-based
    let lineText: String
}

// MARK: - Lexer

enum FormulaLexer {
    fileprivate static func tokenize(_ source: String, basePath: Path) throws -> [TokenWithLocation] {
        var tokens: [TokenWithLocation] = []
        let chars = Array(source)
        var i = 0
        var lineNumber = 1
        var lineStart  = 0   // index of the first character on the current line

        // Current-line text at any point.
        func currentLineText() -> String {
            var end = lineStart
            while end < chars.count && chars[end] != "\n" { end += 1 }
            return String(chars[lineStart..<end])
        }

        // Wraps a FormulaParseError with the current character position (error sites).
        func located(_ error: FormulaParseError) -> FormulaLexerError {
            FormulaLexerError(underlying: error,
                              line: lineNumber,
                              column: i - lineStart + 1,
                              lineText: currentLineText())
        }

        // Token-start location — set just before processing each non-whitespace token.
        var tokLine = 1
        var tokCol  = 1
        var tokText = ""

        // Appends a token tagged with the position captured at tokLine/tokCol/tokText.
        func add(_ tok: FormulaToken) {
            tokens.append(TokenWithLocation(token: tok, line: tokLine, col: tokCol, lineText: tokText))
        }

        while i < chars.count {
            let c = chars[i]

            // Whitespace — track newlines for line/column reporting.
            if c.isWhitespace {
                if c == "\n" { lineNumber += 1; lineStart = i + 1 }
                i += 1; continue
            }

            // // line comment — skip to end of line
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "/" {
                while i < chars.count && chars[i] != "\n" { i += 1 }
                continue
            }

            // Record the start position of this token (after whitespace/comments).
            tokLine = lineNumber
            tokCol  = i - lineStart + 1
            tokText = currentLineText()

            // String literals (single or double quoted)
            if c == "'" || c == "\"" {
                let q = c; i += 1
                var s = ""
                while i < chars.count && chars[i] != q { s.append(chars[i]); i += 1 }
                guard i < chars.count else {
                    throw located(FormulaParseError.unterminatedLiteralString(context: "unterminated string literal"))
                }
                i += 1   // closing quote
                add(.string(s))
                continue
            }

            // Angle-bracket path literal  <rel/path>  — resolved against basePath.
            // Exception: if the content contains '%%', it is a template expression
            // and is emitted raw (without path resolution) so that %%var%% markers
            // survive to evaluation time.
            if c == "<" {
                i += 1   // consume '<'
                var raw = ""
                while i < chars.count && chars[i] != ">" { raw.append(chars[i]); i += 1 }
                guard i < chars.count else {
                    throw located(FormulaParseError.unterminatedPathLiteral(context: "<\(raw)"))
                }
                i += 1   // consume '>'
                if raw.contains("%%") {
                    // Template path: resolve the static prefix (before the first %%) against
                    // basePath so the result has the right input:/... root.
                    // The %%marker%% portion is left intact for eval-time substitution.
                    let templateRange = raw.range(of: "%%")!
                    let staticPrefix  = String(raw[..<templateRange.lowerBound])
                    let remainder     = String(raw[templateRange.lowerBound...])
                    if staticPrefix.isEmpty {
                        add(.string(basePath.string + "/" + remainder))
                    } else {
                        let resolvedPrefix = try resolvePathLiteral(staticPrefix, relativeTo: basePath)
                        let sep = staticPrefix.hasSuffix("/") ? "/" : ""
                        add(.string(resolvedPrefix + sep + remainder))
                    }
                } else {
                    add(.string(try resolvePathLiteral(raw, relativeTo: basePath)))
                }
                continue
            }

            // Single-character tokens
            switch c {
            case "(": add(.lparen);   i += 1
            case ")": add(.rparen);   i += 1
            case "[": add(.lbracket); i += 1
            case "]": add(.rbracket); i += 1
            case "{": add(.lbrace);   i += 1
            case "}": add(.rbrace);   i += 1
            case ",": add(.comma);    i += 1
            case ":": add(.colon);    i += 1
            case "=": add(.equals);   i += 1
            case ".": add(.dot);      i += 1
            default:
                if c.isLetter || c == "_" {
                    var s = ""
                    while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                        s.append(chars[i]); i += 1
                    }
                    switch s {
                    case "func":    add(.kwFunc)
                    case "product": add(.kwProduct)
                    case "include": add(.kwInclude)
                    default:        add(.ident(s))
                    }
                } else {
                    throw located(FormulaParseError.unexpectedCharacter(c, context: ""))
                }
            }
        }

        tokens.append(TokenWithLocation(token: .eof,
                                         line: lineNumber,
                                         col: i - lineStart + 1,
                                         lineText: currentLineText()))
        return tokens
    }

    // Resolves a relative path against basePath, normalising '.' and '..',
    // and errors if the result would escape basePath.
    private static func resolvePathLiteral(_ raw: String, relativeTo basePath: Path, disallowAboveBase: Bool = false) throws -> String {
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
                if disallowAboveBase {
                    guard components.count > baseDepth else {
                        throw FormulaParseError.pathEscapesBasePath(path: raw)
                    }
                }

                // Can't strip first segment
                guard components.count > 1 else {
                    throw FormulaParseError.pathEscapesRoot(path: raw)
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
    private let tokens: [TokenWithLocation]
    private var pos = 0

    init(_ tokens: [TokenWithLocation]) { self.tokens = tokens }

    private var current: FormulaToken { tokens[pos].token }
    private var peek1:   FormulaToken { pos + 1 < tokens.count ? tokens[pos + 1].token : .eof }
    private var peek2:   FormulaToken { pos + 2 < tokens.count ? tokens[pos + 2].token : .eof }

    private mutating func advance() { if pos < tokens.count - 1 { pos += 1 } }

    // Wraps a FormulaParseError with the current token's source location.
    private func located(_ error: FormulaParseError) -> FormulaLexerError {
        let t = tokens[pos]
        return FormulaLexerError(underlying: error, line: t.line, column: t.col, lineText: t.lineText)
    }

    private mutating func expect(_ t: FormulaToken) throws {
        guard current == t else {
            throw located(FormulaParseError.unexpectedToken(current, expected: "\(t)"))
        }
        advance()
    }

    // MARK: Top level

    mutating func parseFile() throws -> FormulaFile {
        var functions: [FuncDef]     = []
        var products:  [ProductDef]  = []
        var includes:  [FormulaInclude] = []
        var namespace: String?

        // `namespace <name>` opens a prelude's text. Not a keyword, so that nothing already
        // spelled `namespace` — a property, a parameter — stops parsing.
        if case .ident("namespace") = current, case .ident(let name) = peek1 {
            advance(); advance()
            namespace = name
        }

        while current != .eof {
            switch current {
            case .kwFunc:
                functions.append(try parseFuncDef())
            case .kwProduct:
                products.append(try parseProductDef())
            case .kwInclude:
                try expect(.kwInclude)
                // `funcs` is not a keyword, for the reason `namespace` is not: it is only a
                // modifier when an expression follows it, so `include funcs(…)` still calls.
                var funcsOnly = false
                if case .ident("funcs") = current {
                    switch peek1 {
                    case .ident, .string:
                        advance()
                        funcsOnly = true
                    default:
                        break
                    }
                }
                includes.append(FormulaInclude(expr: try parseExpr(), funcsOnly: funcsOnly))
            default:
                throw located(FormulaParseError.unexpectedToken(current, expected: "'func', 'product' or 'include'"))
            }
        }

        return FormulaFile(functions: functions, products: products, includes: includes, namespace: namespace)
    }

    // func name(p1, p2, ...) = expr
    private mutating func parseFuncDef() throws -> FuncDef {
        try expect(.kwFunc)
        guard case .ident(let name) = current else {
            throw located(FormulaParseError.unexpectedToken(current, expected: "function name after 'func'"))
        }
        advance()
        try expect(.lparen)
        var params: [String] = []
        while current != .rparen {
            guard case .ident(let p) = current else {
                throw located(FormulaParseError.unexpectedToken(current, expected: "parameter name"))
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
            throw located(FormulaParseError.unexpectedToken(current, expected: "product name string after 'product'"))
        }
        advance()
        try expect(.equals)
        return ProductDef(name: name, body: try parseExpr())
    }

    // MARK: Expressions

    // expr = STRING
    //      | IDENT                               -- parameter reference
    //      | IDENT '(' argList? ')' ('.' IDENT)? -- call / node construct
    //      | IDENT '.' IDENT '(' argList? ')' ('.' IDENT)?  -- call to a prelude's func
    private mutating func parseExpr() throws -> FormulaExpr {
        switch current {
        case .string(let s):
            advance()
            return .string(s)
        case .ident(var name):
            advance()
            // `clang.executable(…)`: a dot between two names is a namespace only when a call
            // follows, which is what keeps it apart from a port suffix — that follows ')'.
            if current == .dot, case .ident(let member) = peek1, peek2 == .lparen {
                advance(); advance()
                name = "\(name).\(member)"
            }
            guard current == .lparen else {
                return .identifier(name)   // no parens → parameter reference
            }
            advance()   // consume '('
            let args = current == .rparen ? [] : try parseArgList()
            try expect(.rparen)
            let port = try parseOptionalPort()
            return .call(name: name, args: args, port: port)
        default:
            throw located(FormulaParseError.unexpectedToken(current, expected: "expression"))
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

    // arg = IDENT ':' '[' wireDict ']'              -- input-wire port (wire dict starts with '[')
    //     | IDENT ':' expr                           -- labeled arg or node property
    //     | IDENT ('.' IDENT)+ ':' expr              -- dotted property key (e.g. toolDescriptor.name: "clang")
    //     | expr                                     -- positional
    //
    // A '[' immediately after ':' distinguishes a wire port from a property value.
    // Dotted keys use position-saving backtracking and are always property values.
    private mutating func parseArg() throws -> FormulaCallArg {
        if case .ident(let name) = current {
            if peek1 == .colon {
                advance(); advance()   // consume IDENT and :
                if current == .lbracket {
                    return .inputWire(portName: name, wires: try parseWireDict())
                }
                return .labeled(key: name, value: try parseExpr())
            }
            // Dotted property key: e.g. toolDescriptor.name: "clang"
            if peek1 == .dot {
                let savedPos = pos
                var key = name
                advance()           // consume leading IDENT
                while current == .dot {
                    advance()       // consume '.'
                    guard case .ident(let part) = current else {
                        pos = savedPos; break
                    }
                    key += "." + part
                    advance()       // consume part
                }
                if current == .colon {
                    advance()       // consume ':'
                    return .labeled(key: key, value: try parseExpr())
                }
                pos = savedPos      // not a dotted key — restore for positional fallthrough
            }
        }
        return .positional(try parseExpr())
    }

    // '[' (wireEntry (',' wireEntry)*)? ']'
    // wireEntry = forEachPrefix? (STRING | PATH) ':' expr
    // forEachPrefix = '{' IDENT ':' items ('except' items)? '}'
    private mutating func parseWireDict() throws -> [WireDictEntry] {
        try expect(.lbracket)
        var entries: [WireDictEntry] = []
        while current != .rbracket {
            if current == .lbrace {
                entries.append(try parseForEachEntry())
            } else {
                // Detect optional explicit key: (string | ident) immediately followed by ':'.
                // Anything else is an unnamed wire — auto-generate "wireN" at resolve time.
                let hasKey: Bool
                switch current {
                case .string, .ident: hasKey = (peek1 == .colon)
                default:              hasKey = false
                }

                if hasKey {
                    let keyExpr: FormulaExpr
                    switch current {
                    case .string(let s): advance(); keyExpr = .string(s)
                    case .ident(let n):  advance(); keyExpr = .identifier(n)
                    default: fatalError("unreachable")
                    }
                    try expect(.colon)
                    entries.append(.simple(key: keyExpr, value: try parseExpr()))
                } else {
                    entries.append(.unnamed(value: try parseExpr()))
                }
            }
            if current == .comma { advance() }
        }
        try expect(.rbracket)
        return entries
    }

    // '{' IDENT ':' items ('except' items)? '}' (STRING | PATH) ':' expr
    private mutating func parseForEachEntry() throws -> WireDictEntry {
        try expect(.lbrace)
        guard case .ident(let variable) = current else {
            throw located(FormulaParseError.unexpectedToken(current, expected: "variable name in for-each '{var: ...}'"))
        }
        advance()
        try expect(.colon)

        let items = try parseForEachItems(after: "'\(variable):'")
        var excluded: [FormulaExpr] = []
        if atExceptKeyword {
            advance()
            excluded = try parseForEachItems(after: "'except'")
        }
        try expect(.rbrace)

        guard !items.isEmpty else {
            throw located(FormulaParseError.forEachRequiresAtLeastOneItem)
        }

        // Key template: the wire dict key, may contain %%variable%%.
        guard case .string(let key) = current else {
            throw located(FormulaParseError.unexpectedToken(current, expected: "wire key template after for-each '{...}'"))
        }
        advance()
        try expect(.colon)

        return .forEach(variable: variable, items: items, excluded: excluded, key: key, value: try parseExpr())
    }

    /// One or more for-each items, separated by commas, up to the `}` or the `except` that
    /// ends them. `context` names what they follow, for the error when one is not an item.
    private mutating func parseForEachItems(after context: String) throws -> [FormulaExpr] {
        var items: [FormulaExpr] = []
        repeat {
            switch current {
            case .string(let item):
                items.append(.string(item))
                advance()
            case .ident(let name):
                items.append(.identifier(name))
                advance()
            default:
                throw located(FormulaParseError.unexpectedToken(current,
                                                                 expected: "for-each item (string, path, or parameter name) after \(context)"))
            }
            if current == .comma { advance() }
        } while current != .rbrace && !atExceptKeyword
        return items
    }

    /// Whether `except` here opens a for-each's exclusions rather than naming a parameter.
    ///
    /// Not a keyword, for the reason `namespace` and `funcs` are not: a func, a parameter or a
    /// wire already spelled `except` must keep working. The loop above asks only after it has
    /// read an item, and the word opens the exclusions only when another item follows it, so
    /// `{f: except}` and `{f: 'a', except}` still iterate a parameter of that name.
    private var atExceptKeyword: Bool {
        guard case .ident("except") = current else {
            return false
        }
        switch peek1 {
        case .string, .ident:
            return true
        default:
            return false
        }
    }

    // ('.' IDENT)?
    private mutating func parseOptionalPort() throws -> String? {
        guard current == .dot else {
            return nil
        }
        advance()
        guard case .ident(let port) = current else {
            throw located(FormulaParseError.unexpectedToken(current, expected: "port name after '.'"))
        }
        advance()
        return port
    }
}

// MARK: - Resolver

private enum FormulaValue {
    case node(GraphSpecNode)
    case string(String)

    var typeName: String { switch self { case .node: return "node"; case .string: return "string" } }
}

// MARK: - For-each template expansion

/// Captures the expansion of a single for-each variable binding.
private struct ForEachBinding {
    let variable: String
    let full:     String       // %%variable%%
    let groups:   [String]     // %%variable.0%%, %%variable.1%%, ...

    /// Containing directory path with a trailing slash, derived from `full`.
    /// e.g.  "src/hello.c" → "src/"
    ///        "hello.c"    → ""
    var folder: String {
        guard let slash = full.lastIndex(of: "/") else {
            return ""
        }
        return String(full[...slash])
    }
}

/// Expand all `%%var%%`, `%%var.N%%`, and `%%var.folder%%` markers in `s`.
private func expandTemplate(_ s: String, templateEnv: [String: ForEachBinding]) -> String {
    guard s.contains("%%") else {
        return s
    }
    var result = s
    for (_, binding) in templateEnv {
        let v = binding.variable
        result = result.replacingOccurrences(of: "%%\(v)%%",        with: binding.full)
        result = result.replacingOccurrences(of: "%%\(v).folder%%", with: binding.folder)
        for (i, group) in binding.groups.enumerated() {
            result = result.replacingOccurrences(of: "%%\(v).\(i)%%", with: group)
        }
    }
    return result
}

// MARK: - Glob capture-group extraction

/// Given a wildcard `pattern` and a confirmed `match`, extract the text captured by
/// each `*` wildcard in the pattern (left-to-right), excluding `**` doubleStars.
/// Use `%%var.folder%%` to access the directory depth captured by `**` instead.
private func extractCaptureGroups(pattern: String, match: String) -> [String] {
    let patSegs   = pattern.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    let matchSegs = match.split(separator:   "/", omittingEmptySubsequences: false).map(String.init)

    var groups: [String] = []
    var matchIdx = 0

    for patSeg in patSegs {
        guard matchIdx < matchSegs.count else { break }
        if patSeg == "**" {
            // Globstar contributes no capture group; use %%var.folder%% for directory depth.
            continue
        }
        if patSeg.contains("*") || patSeg.contains("?") {
            groups.append(contentsOf: extractSegmentCaptures(pattern: patSeg,
                                                             text: matchSegs[matchIdx]))
        }
        matchIdx += 1
    }
    return groups
}

/// Extract wildcard captures from a single path-segment pattern vs a matching segment text.
/// Each `*` contributes one capture group (greedy, stopped by the next literal character).
/// `?` matches one character without contributing a group.
private func extractSegmentCaptures(pattern: String, text: String) -> [String] {
    var groups: [String] = []
    let patChars  = Array(pattern)
    let textChars = Array(text)
    var pi = 0, ti = 0

    while pi < patChars.count {
        switch patChars[pi] {
        case "*":
            pi += 1
            // Determine the next literal in the pattern (skip consecutive wildcards).
            var nextLit: Character?
            var look = pi
            while look < patChars.count && (patChars[look] == "*" || patChars[look] == "?") { look += 1 }
            nextLit = look < patChars.count ? patChars[look] : nil
            // Greedily consume text until nextLit (or end of text).
            var captured = ""
            while ti < textChars.count {
                if let nl = nextLit, textChars[ti] == nl { break }
                captured.append(textChars[ti]); ti += 1
            }
            groups.append(captured)
        case "?":
            pi += 1; ti += 1
        default:
            guard pi < patChars.count && ti < textChars.count,
                  patChars[pi] == textChars[ti] else {
                return groups
            }
            pi += 1; ti += 1
        }
    }
    return groups
}

// MARK: - Resolver

private struct FormulaResolver {
    let functions:  [String: FuncDef]
    let products:   [ProductDef]
    let wildcardExpander:    (String) throws -> [String]
    let fileReader: (String) throws -> String?

    init(_ file: FormulaFile,
         wildcardExpander:    @escaping (String) throws -> [String],
         fileReader: @escaping (String) throws -> String?) {
        functions        = Dictionary(uniqueKeysWithValues: file.functions.map { ($0.name, $0) })
        products         = file.products
        self.wildcardExpander     = wildcardExpander
        self.fileReader  = fileReader
    }

    func resolve() throws -> [String: GraphSpecNode] {
        var result: [String: GraphSpecNode] = [:]
        for product in products {
            let value = try eval(product.body, env: [:], templateEnv: [:])
            guard case .node(let node) = value else {
                throw FormulaParseError.typeMismatch(
                    expected: "node", got: value.typeName,
                    context: "product '\(product.name)' must resolve to a node")
            }
            result[product.name] = node
        }
        return result
    }

    /// The node an `include` statement names, resolved like a product body.
    ///
    /// A string names a plugin's prelude (B-108): `include 'clang'` is the `FormulaPrelude`
    /// node for that name, whose output is the text the plugin provides.
    func resolve(include expr: FormulaExpr) throws -> GraphSpecNode {
        switch try eval(expr, env: [:], templateEnv: [:]) {
        case .node(let node):
            return node
        case .string(let name):
            return FormulaPrelude.spec(forIncludeNamed: name)
        }
    }

    // MARK: Evaluation

    func eval(
        _ expr: FormulaExpr,
        env: [String: FormulaValue],
        templateEnv: [String: ForEachBinding]
    ) throws -> FormulaValue {
        switch expr {

        case .string(let s):
            // Apply %%var%% template substitution when a for-each binding is in scope.
            return .string(expandTemplate(s, templateEnv: templateEnv))

        case .identifier(let name):
            // Parameter reference — must be bound in the current environment.
            guard let value = env[name] else {
                throw FormulaParseError.undefinedIdentifier(name)
            }
            return value

        case .call(let name, let args, let port):
            if name == "import" {
                return try evalImport(args: args, port: port, env: env, templateEnv: templateEnv)
            }
            if let funcDef = functions[name] {
                // User-defined function: no .port suffix → preserve the function's own return port.
                let base = try evalFuncCall(funcDef, args: args, env: env, templateEnv: templateEnv)
                guard let port else {
                    return base
                }
                guard case .node(let node) = base else {
                    throw FormulaParseError.typeMismatch(
                        expected: "node (for port access '.\(port)')", got: base.typeName,
                        context: "cannot access an output port on a string value")
                }
                return .node(GraphSpecNode(typeName: node.typeName,
                                             properties: node.properties,
                                             inputs:  node.inputs,
                                             outputs: node.outputs,
                                             outputPort: port))
            } else {
                // Node constructor: no .port suffix → resolved here against the registered
                // type's descriptor.  Nothing downstream understands "_default", so it only
                // survives for a type TypeRegistry does not know about.
                let base = try evalNodeConstruct(typeName: name, args: args, env: env, templateEnv: templateEnv)
                guard case .node(let node) = base else {
                    throw FormulaParseError.typeMismatch(
                        expected: "node", got: base.typeName,
                        context: "node constructor '\(name)' did not return a node")
                }
                return .node(GraphSpecNode(typeName: node.typeName,
                                             properties: node.properties,
                                             inputs:  node.inputs,
                                             outputs: node.outputs,
                                             outputPort: port ?? resolveDefaultOutputPort(forTypeName: name)))
            }
        }
    }

    /// A user-defined function call: the arguments are evaluated where the call is, and the
    /// body where the function is.
    ///
    /// The body sees its parameters and nothing of the caller's — neither its parameters
    /// nor its for-each bindings. A func may be written by someone other than the formula
    /// that calls it (a plugin's prelude, B-108), so a `%%f%%` in its body must not expand
    /// to whatever `f` the caller happens to be iterating, and a parameter the caller left
    /// out must not be filled by a caller's variable of the same name.
    ///
    /// A string argument is also a template variable in the body: `'%%sources%%/*.c'` is how
    /// a func turns the folder it was given into the pattern it matches.
    func evalFuncCall(
        _ funcDef: FuncDef,
        args: [FormulaCallArg],
        env: [String: FormulaValue],
        templateEnv: [String: ForEachBinding]
    ) throws -> FormulaValue {
        var newEnv: [String: FormulaValue] = [:]
        var positionalIdx = 0

        for arg in args {
            switch arg {
            case .positional(let expr):
                guard positionalIdx < funcDef.params.count else {
                    throw FormulaParseError.wrongArgumentCount(
                        function: funcDef.name, expected: funcDef.params.count, got: positionalIdx + 1)
                }
                newEnv[funcDef.params[positionalIdx]] = try eval(expr, env: env, templateEnv: templateEnv)
                positionalIdx += 1

            case .labeled(let key, let expr):
                guard funcDef.params.contains(key) else {
                    throw FormulaParseError.undefinedIdentifier(
                        "parameter '\(key)' in function '\(funcDef.name)'")
                }
                newEnv[key] = try eval(expr, env: env, templateEnv: templateEnv)

            case .inputWire:
                throw FormulaParseError.typeMismatch(
                    expected: "value argument", got: "wire dict '[...]'",
                    context: "wire syntax is not valid when calling function '\(funcDef.name)'")
            }
        }

        var bodyTemplateEnv: [String: ForEachBinding] = [:]
        for parameter in funcDef.params {
            guard let value = newEnv[parameter] else {
                throw FormulaParseError.unboundParameter(function: funcDef.name, parameter: parameter)
            }
            if case .string(let text) = value {
                bodyTemplateEnv[parameter] = ForEachBinding(variable: parameter, full: text, groups: [])
            }
        }

        return try eval(funcDef.body, env: newEnv, templateEnv: bodyTemplateEnv)
    }

    // import(path: <file>) — reads an external .graph file and returns its root node.
    // If the file is not yet available the fileReader returns nil; we substitute a
    // placeholder node so that the rest of the formula continues to evaluate (allowing
    // all other dependency paths — globs, other imports — to be recorded).  The caller
    // is responsible for suppressing product specs when anyImportMissing is set.
    private func evalImport(
        args: [FormulaCallArg],
        port: String?,
        env: [String: FormulaValue],
        templateEnv: [String: ForEachBinding]
    ) throws -> FormulaValue {
        guard args.count == 1,
              case .labeled(let key, let pathExpr) = args[0],
              key == "path"
        else {
            throw FormulaParseError.typeMismatch(
                expected: "import(path: <file>)",
                got: "unexpected arguments",
                context: "import() requires exactly one 'path:' labeled argument")
        }

        let pathValue = try eval(pathExpr, env: env, templateEnv: templateEnv)
        guard case .string(let path) = pathValue else {
            throw FormulaParseError.typeMismatch(
                expected: "string",
                got: pathValue.typeName,
                context: "import path must resolve to a string")
        }

        guard let content = try fileReader(path) else {
            // File not yet wired — return a placeholder so dependency recording continues.
            return .node(GraphSpecNode(typeName: "__ImportPending__"))
        }

        let baseNode       = try GraphSpecNode.parse(content)
        let effectivePort  = port ?? baseNode.outputPort ?? resolveDefaultOutputPort(forTypeName: baseNode.typeName)
        return .node(GraphSpecNode(typeName:   baseNode.typeName,
                                     properties: baseNode.properties,
                                     inputs:     baseNode.inputs,
                                     outputs:    baseNode.outputs,
                                     outputPort: effectivePort))
    }

    // Node construction: map labeled args → GraphSpecProperty, wires → GraphSpecInputPort.
    func evalNodeConstruct(
        typeName: String,
        args: [FormulaCallArg],
        env: [String: FormulaValue],
        templateEnv: [String: ForEachBinding]
    ) throws -> FormulaValue {
        var nodeProps:  [GraphSpecProperty]  = []
        var inputPorts: [GraphSpecInputPort] = []

        for arg in args {
            switch arg {
            case .labeled(let key, let expr):
                let value = try eval(expr, env: env, templateEnv: templateEnv)
                guard case .string(let s) = value else {
                    throw FormulaParseError.typeMismatch(
                        expected: "string (property '\(key)' of '\(typeName)')",
                        got: value.typeName,
                        context: "node property values must be string expressions")
                }
                nodeProps.append(GraphSpecProperty(key: key, value: s))

            case .inputWire(let portName, let entries):
                var graphWires: [GraphSpecWire] = []
                for entry in entries {
                    switch entry {
                    case .simple(let keyExpr, let expr):
                        let keyValue = try eval(keyExpr, env: env, templateEnv: templateEnv)
                        guard case .string(let key) = keyValue else {
                            throw FormulaParseError.typeMismatch(
                                expected: "string (wire key on port '\(portName)' of '\(typeName)')",
                                got: keyValue.typeName,
                                context: "wire key must resolve to a string")
                        }
                        let value = try eval(expr, env: env, templateEnv: templateEnv)
                        guard case .node(let node) = value else {
                            throw FormulaParseError.typeMismatch(
                                expected: "node (wire '\(key)' on port '\(portName)' of '\(typeName)')",
                                got: value.typeName,
                                context: "wire values must be node expressions")
                        }
                        graphWires.append(GraphSpecWire(name: key, node: node))

                    case .unnamed(let expr):
                        let value = try eval(expr, env: env, templateEnv: templateEnv)
                        guard case .node(let node) = value else {
                            throw FormulaParseError.typeMismatch(
                                expected: "node (unnamed wire on port '\(portName)' of '\(typeName)')",
                                got: value.typeName,
                                context: "wire values must be node expressions")
                        }
                        graphWires.append(GraphSpecWire(name: "wire\(graphWires.count)", node: node))

                    case .forEach(let variable, let itemExprs, let excludedExprs, let key, let expr):
                        let bindings = try forEachBindings(variable:    variable,
                                                           items:       itemExprs,
                                                           excluded:    excludedExprs,
                                                           env:         env,
                                                           templateEnv: templateEnv)
                        for binding in bindings {
                            var newTemplateEnv = templateEnv
                            newTemplateEnv[variable] = binding
                            var newEnv = env
                            newEnv[variable] = .string(binding.full)
                            let expandedKey = expandTemplate(key, templateEnv: newTemplateEnv)
                            let value = try eval(expr, env: newEnv, templateEnv: newTemplateEnv)
                            guard case .node(let node) = value else {
                                throw FormulaParseError.typeMismatch(
                                    expected: "node (for-each wire '\(expandedKey)' on port '\(portName)' of '\(typeName)')",
                                    got: value.typeName,
                                    context: "wire values must be node expressions")
                            }
                            graphWires.append(GraphSpecWire(name: expandedKey, node: node))
                        }
                    }
                }
                inputPorts.append(GraphSpecInputPort(portName: portName, wires: graphWires))

            case .positional:
                throw FormulaParseError.positionalArgInNodeConstruction(typeName: typeName)
            }
        }

        return .node(GraphSpecNode(typeName: typeName, properties: nodeProps, inputs: inputPorts))
    }

    // MARK: Output port resolution

    /// Resolves the `_default` output port placeholder to a concrete port name.
    func resolveDefaultOutputPort(forTypeName typeName: String) -> String {
        guard let nodeType = TypeRegistry.nodeType(forTypeName: typeName) as? Node.Type else {
            return "_default"
        }
        let ports = nodeType.descriptor.outputPorts
        if ports.count == 1 { return ports[0] }
        if ports.contains("output") { return "output" }
        return "_default"
    }

    // MARK: For-each item expansion

    /// What a for-each iterates: its items expanded, less every path its `except` items
    /// expand to. The two lists meet as expanded paths, not as the text written, so
    /// `<*.c> except <lua.c>` removes the match the pattern made for `lua.c`: both spellings
    /// went through the lexer's path resolution and the expander hands back the same form.
    ///
    /// An `except` item that matches nothing is neither an error nor a notice. A project
    /// keeps an exclusion after upstream deletes the file — the formula then builds either
    /// side of that commit — and the resolver cannot tell that case from the one it runs into
    /// on every build: the first pass, before any folder manifest has arrived, expands every
    /// pattern to nothing, so a notice there would be noise each time.
    ///
    /// For the same reason the error is for an `except` that *removes* everything, not for an
    /// empty result: items that expanded to nothing are the first pass, or a pattern that
    /// matches nothing, and neither is an error without `except` either.
    private func forEachBindings(
        variable: String,
        items: [FormulaExpr],
        excluded: [FormulaExpr],
        env: [String: FormulaValue],
        templateEnv: [String: ForEachBinding]
    ) throws -> [ForEachBinding] {
        let bindings = try expandForEachItems(variable: variable,
                                              items:    evalForEachItems(items, env: env, templateEnv: templateEnv))
        guard !excluded.isEmpty else {
            return bindings
        }
        let excludedBindings = try expandForEachItems(variable: variable,
                                                      items:    evalForEachItems(excluded, env: env, templateEnv: templateEnv))
        let excludedPaths = Set(excludedBindings.map(\.full))
        let kept = bindings.filter { !excludedPaths.contains($0.full) }
        guard kept.isEmpty, !bindings.isEmpty else {
            return kept
        }
        throw FormulaParseError.forEachExceptLeavesNothing(variable: variable, removed: bindings.map(\.full))
    }

    /// Each for-each item's text: a literal, a pattern, or the string a parameter holds.
    private func evalForEachItems(
        _ itemExprs: [FormulaExpr],
        env: [String: FormulaValue],
        templateEnv: [String: ForEachBinding]
    ) throws -> [String] {
        try itemExprs.map { itemExpr in
            let itemValue = try eval(itemExpr, env: env, templateEnv: templateEnv)
            guard case .string(let item) = itemValue else {
                throw FormulaParseError.typeMismatch(
                    expected: "string (for-each item)",
                    got: itemValue.typeName,
                    context: "for-each items must resolve to strings")
            }
            return item
        }
    }

    private func expandForEachItems(variable: String, items: [String]) throws -> [ForEachBinding] {
        var bindings: [ForEachBinding] = []
        for item in items {
            if item.contains("*") || item.contains("?") {
                let matches = try wildcardExpander(item)
                for match in matches {
                    bindings.append(ForEachBinding(
                        variable: variable,
                        full:     match,
                        groups:   extractCaptureGroups(pattern: item, match: match)
                    ))
                }
            } else {
                bindings.append(ForEachBinding(variable: variable, full: item, groups: []))
            }
        }
        return bindings
    }
}
