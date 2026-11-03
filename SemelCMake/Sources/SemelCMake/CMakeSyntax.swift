//
//  CMakeSyntax.swift
//  SemelCMake
//
//  The CMake language as text: commands, each a name and its arguments, with the line
//  each starts on. This stage knows nothing of what a command means — `if`, `endif` and
//  `add_executable` are the same thing here, a name with arguments — and nothing of what a
//  variable holds: an argument keeps its `${VAR}` references as parts, unexpanded, because
//  expansion is semantics and a quoted argument expands differently from an unquoted one.
//
//  The grammar is cmake-language(7)'s: a file is command invocations and comments; an
//  argument is bracket (`[[…]]`, taken verbatim), quoted (`"…"`, escapes and references,
//  one argument whatever it holds) or unquoted (escapes and references, and later split on
//  `;`). Parentheses inside an argument list are arguments of their own, `(` and `)`,
//  which is how `if((A AND B) OR C)` reaches the evaluator.
//

/// One `${…}`-shaped piece of an argument, or the text between them.
public indirect enum CMakeArgumentPart: Equatable {
    case literal(String)
    /// `${…}`: the name is itself parts, since `${${PREFIX}_DIR}` is legal.
    case variable([CMakeArgumentPart])
    /// `$ENV{NAME}`.
    case environment(String)
    /// `$<…>`, kept as its text: the evaluator refuses it, and names it.
    case generatorExpression(String)
}

public struct CMakeArgument: Equatable {
    public enum Form: Equatable {
        case unquoted
        case quoted
        case bracket
    }

    public var form: Form
    public var parts: [CMakeArgumentPart]

    public init(form: Form, parts: [CMakeArgumentPart]) {
        self.form  = form
        self.parts = parts
    }

    /// The text when the argument holds no reference, nil otherwise: what a keyword
    /// argument has to be — `PUBLIC`, `STATIC` — to be read as one.
    public var literalText: String? {
        var text = ""
        for part in parts {
            guard case .literal(let piece) = part else {
                return nil
            }
            text += piece
        }
        return text
    }

    /// A literal unquoted argument, the way a keyword is written.
    public static func unquoted(_ text: String) -> CMakeArgument {
        CMakeArgument(form: .unquoted, parts: text.isEmpty ? [] : [.literal(text)])
    }
}

public struct CMakeCommand: Equatable {
    /// Lowercased: command names are case-insensitive, and `ADD_EXECUTABLE` is still met.
    public var name: String
    public var arguments: [CMakeArgument]
    public var location: CMakeLocation

    public init(name: String, arguments: [CMakeArgument], location: CMakeLocation) {
        self.name      = name
        self.arguments = arguments
        self.location  = location
    }
}

/// One `CMakeLists.txt` or `.cmake` file, parsed.
public struct CMakeFile: Equatable {
    /// Relative to the project root: `CMakeLists.txt`, `src/CMakeLists.txt`.
    public var path: String
    public var commands: [CMakeCommand]

    public init(path: String, commands: [CMakeCommand]) {
        self.path     = path
        self.commands = commands
    }

    public static func parse(_ text: String, path: String) throws -> CMakeFile {
        var parser = CMakeParser(text: text, path: path)
        return CMakeFile(path: path, commands: try parser.parseFile())
    }
}

public enum CMakeSyntaxError: Error, Equatable {
    case unexpectedCharacter(Character, at: CMakeLocation)
    case missingOpeningParenthesis(command: String, at: CMakeLocation)
    case unterminatedArguments(command: String, at: CMakeLocation)
    case unterminatedQuotedArgument(at: CMakeLocation)
    case unterminatedBracket(at: CMakeLocation)
    case unterminatedVariableReference(at: CMakeLocation)
}

// MARK: - Parser

struct CMakeParser {
    private let characters: [Character]
    private let path: String
    private var index = 0
    private var line  = 1

    /// A file with Windows line ends reads as one with Unix ones: Swift makes `\r\n` a
    /// single `Character`, which is neither the `\n` a comment or a line count ends at
    /// nor whitespace, so a file written that way would parse as one unending line.
    init(text: String, path: String) {
        characters = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))
        self.path  = path
    }

    private var location: CMakeLocation { CMakeLocation(file: path, line: line) }

    private var current: Character? { index < characters.count ? characters[index] : nil }

    private func peek(_ offset: Int) -> Character? {
        index + offset < characters.count ? characters[index + offset] : nil
    }

    private mutating func advance() {
        if current == "\n" {
            line += 1
        }
        index += 1
    }

    mutating func parseFile() throws -> [CMakeCommand] {
        var commands: [CMakeCommand] = []
        while let character = current {
            if character.isWhitespace {
                advance()
                continue
            }
            if character == "#" {
                try skipComment()
                continue
            }
            guard character.isLetter || character == "_" else {
                throw CMakeSyntaxError.unexpectedCharacter(character, at: location)
            }
            commands.append(try parseCommand())
        }
        return commands
    }

    private mutating func parseCommand() throws -> CMakeCommand {
        let start = location
        var name = ""
        while let character = current, character.isLetter || character.isNumber || character == "_" {
            name.append(character)
            advance()
        }
        while let character = current, character == " " || character == "\t" {
            advance()
        }
        guard current == "(" else {
            throw CMakeSyntaxError.missingOpeningParenthesis(command: name, at: start)
        }
        advance()
        let arguments = try parseArguments(command: name, start: start)
        return CMakeCommand(name: name.lowercased(), arguments: arguments, location: start)
    }

    /// Everything up to the `)` that closes the command. A `(` inside is an argument, and
    /// so is the `)` that matches it; only the outermost one ends the list.
    private mutating func parseArguments(command: String, start: CMakeLocation) throws -> [CMakeArgument] {
        var arguments: [CMakeArgument] = []
        var depth = 0
        while let character = current {
            if character.isWhitespace {
                advance()
                continue
            }
            switch character {
            case "#":
                try skipComment()
            case ")":
                advance()
                if depth == 0 {
                    return arguments
                }
                depth -= 1
                arguments.append(.unquoted(")"))
            case "(":
                advance()
                depth += 1
                arguments.append(.unquoted("("))
            case "\"":
                arguments.append(try parseQuotedArgument())
            case "[" where isBracketOpening():
                arguments.append(try parseBracketArgument())
            default:
                arguments.append(try parseUnquotedArgument())
            }
        }
        throw CMakeSyntaxError.unterminatedArguments(command: command, at: start)
    }

    /// Whether the text at the index is `[`, any `=`s, `[`: a bracket argument or comment.
    private func isBracketOpening() -> Bool {
        var offset = 1
        while peek(offset) == "=" {
            offset += 1
        }
        return peek(offset) == "["
    }

    private mutating func skipComment() throws {
        advance()  // the #
        if current == "[", isBracketOpening() {
            _ = try parseBracketArgument()
            return
        }
        while let character = current, character != "\n" {
            advance()
        }
    }

    /// `[=*[` … `]=*]` with the same number of `=`, verbatim: no escape, no reference.
    private mutating func parseBracketArgument() throws -> CMakeArgument {
        let start = location
        advance()  // [
        var equals = 0
        while current == "=" {
            equals += 1
            advance()
        }
        advance()  // the second [
        // A newline directly after the opening is not part of the text.
        if current == "\n" {
            advance()
        }
        let closing = "]" + String(repeating: "=", count: equals) + "]"
        var text = ""
        while current != nil {
            if matches(closing) {
                for _ in closing {
                    advance()
                }
                return CMakeArgument(form: .bracket, parts: text.isEmpty ? [] : [.literal(text)])
            }
            if let character = current {
                text.append(character)
            }
            advance()
        }
        throw CMakeSyntaxError.unterminatedBracket(at: start)
    }

    private func matches(_ text: String) -> Bool {
        for (offset, character) in text.enumerated() where peek(offset) != character {
            return false
        }
        return true
    }

    /// `"` … `"`, the raw text kept with its escapes for the part parser, which knows that
    /// a `\` before a newline joins the lines.
    private mutating func parseQuotedArgument() throws -> CMakeArgument {
        let start = location
        advance()  // the opening quote
        var raw = ""
        while let character = current {
            if character == "\\" {
                raw.append(character)
                advance()
                if let escaped = current {
                    raw.append(escaped)
                    advance()
                }
                continue
            }
            if character == "\"" {
                advance()
                return CMakeArgument(form: .quoted, parts: try parts(ofRaw: raw, at: start))
            }
            raw.append(character)
            advance()
        }
        throw CMakeSyntaxError.unterminatedQuotedArgument(at: start)
    }

    /// Up to whitespace, a parenthesis or a comment. A quoted run inside — `-DX="y"`, the
    /// legacy form — is kept with its quotes, as CMake keeps them.
    private mutating func parseUnquotedArgument() throws -> CMakeArgument {
        let start = location
        var raw = ""
        while let character = current {
            if character.isWhitespace || character == "(" || character == ")" || character == "#" {
                break
            }
            if character == "\\" {
                raw.append(character)
                advance()
                if let escaped = current {
                    raw.append(escaped)
                    advance()
                }
                continue
            }
            if character == "\"" {
                raw.append(character)
                advance()
                while let inner = current, inner != "\"" {
                    raw.append(inner)
                    advance()
                }
                if current == "\"" {
                    raw.append("\"")
                    advance()
                }
                continue
            }
            raw.append(character)
            advance()
        }
        return CMakeArgument(form: .unquoted, parts: try parts(ofRaw: raw, at: start))
    }

    // MARK: Parts

    /// Escapes resolved and references found. An escaped `$` is a `$`, so the two cannot
    /// be separate passes.
    private func parts(ofRaw raw: String, at start: CMakeLocation) throws -> [CMakeArgumentPart] {
        var scanner = PartScanner(characters: Array(raw), location: start)
        let parts = try scanner.scan(until: nil)
        return parts
    }
}

/// Reads the parts of one argument's raw text. Recursive for `${${X}_Y}`: a reference's
/// name is scanned with the same rules, up to its `}`.
private struct PartScanner {
    let characters: [Character]
    let location: CMakeLocation
    var index = 0

    init(characters: [Character], location: CMakeLocation) {
        self.characters = characters
        self.location   = location
    }

    private var current: Character? { index < characters.count ? characters[index] : nil }

    private func peek(_ offset: Int) -> Character? {
        index + offset < characters.count ? characters[index + offset] : nil
    }

    private func matches(_ text: String) -> Bool {
        for (offset, character) in text.enumerated() where peek(offset) != character {
            return false
        }
        return true
    }

    mutating func scan(until terminator: Character?) throws -> [CMakeArgumentPart] {
        var parts: [CMakeArgumentPart] = []
        var literal = ""
        func flush() {
            if !literal.isEmpty {
                parts.append(.literal(literal))
                literal = ""
            }
        }
        while let character = current {
            if let terminator, character == terminator {
                flush()
                return parts
            }
            if character == "\\" {
                index += 1
                guard let escaped = current else {
                    literal.append("\\")
                    break
                }
                index += 1
                switch escaped {
                case "n":  literal.append("\n")
                case "t":  literal.append("\t")
                case "r":  literal.append("\r")
                case "\n": break  // a continued line
                // ISSUE: `\;` is a `;` that does not separate list elements, and a literal
                // `;` here will. Rare enough that no part marks the difference yet.
                default:   literal.append(escaped)
                }
                continue
            }
            if character == "$" {
                if matches("${") {
                    flush()
                    index += 2
                    let name = try scan(until: "}")
                    guard current == "}" else {
                        throw CMakeSyntaxError.unterminatedVariableReference(at: location)
                    }
                    index += 1
                    parts.append(.variable(name))
                    continue
                }
                if matches("$ENV{") || matches("$CACHE{") {
                    let isEnvironment = matches("$ENV{")
                    flush()
                    index += isEnvironment ? 5 : 7
                    var name = ""
                    while let inner = current, inner != "}" {
                        name.append(inner)
                        index += 1
                    }
                    guard current == "}" else {
                        throw CMakeSyntaxError.unterminatedVariableReference(at: location)
                    }
                    index += 1
                    // A cache variable reads as the variable of that name: the subset has
                    // one table, where `set(… CACHE …)` writes a default.
                    parts.append(isEnvironment ? .environment(name) : .variable([.literal(name)]))
                    continue
                }
                if matches("$<") {
                    flush()
                    var text = ""
                    var depth = 0
                    while let inner = current {
                        text.append(inner)
                        index += 1
                        if inner == "<" {
                            depth += 1
                        }
                        if inner == ">" {
                            depth -= 1
                            if depth == 0 {
                                break
                            }
                        }
                    }
                    // An unquoted argument ends at whitespace, so a `$<` whose `>` is on a
                    // later line is a part that ends with the argument, as CMake reads it;
                    // the evaluator refuses the command for the expression either way.
                    parts.append(.generatorExpression(text))
                    continue
                }
            }
            literal.append(character)
            index += 1
        }
        if terminator != nil {
            throw CMakeSyntaxError.unterminatedVariableReference(at: location)
        }
        flush()
        return parts
    }
}
