//
//  Xcconfig.swift
//  SemelApple
//
//  An `.xcconfig` file the way Xcode reads it: assignments and includes, in the order they
//  are written, because the order is the meaning — a later assignment of a setting
//  overrides an earlier one, `$(inherited)` in it reaches back to the earlier one, and an
//  include is read at the line that names it. A parsed file is a value; the files it
//  includes are found by whoever holds them (the converter demands each as a
//  `StaticFile`; `prepare` reads the disk), and `XcconfigExpansion` splices them in.

import Foundation

// MARK: - Assignments

/// One condition on an assignment: `sdk=macosx*`, `config=Debug`, `arch=arm64`. The
/// pattern may hold `*`, which matches any run of characters.
struct XcodeSettingCondition: Equatable {
    let parameter: String
    let pattern: String

    /// Whether the condition holds for a build in `context`. A parameter the converter
    /// cannot know at this level — `dialect`, which is per source file — never holds:
    /// a setting meant for one language is better left out than applied to all.
    func holds(in context: XcodeSettingContext) -> Bool {
        let value: String
        switch parameter {
        case "sdk":     value = context.sdk
        case "config":  value = context.configuration
        case "arch":    value = context.architecture
        case "variant": value = context.variant
        default:        return false
        }
        return Self.glob(pattern, matches: value)
    }

    /// `*` as any run of characters, everything else literally — the only wildcard the
    /// conditions projects write use.
    static func glob(_ pattern: String, matches value: String) -> Bool {
        let pieces = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count > 1 else {
            return pattern == value
        }
        guard let first = pieces.first, let last = pieces.last, value.hasPrefix(first) else {
            return false
        }
        var remainder = Substring(value.dropFirst(first.count))
        for piece in pieces.dropFirst().dropLast() where !piece.isEmpty {
            guard let found = remainder.range(of: piece) else {
                return false
            }
            remainder = remainder[found.upperBound...]
        }
        return remainder.count >= last.count && remainder.hasSuffix(last)
    }
}

/// What a condition is evaluated against: one build's SDK, configuration, architecture
/// and variant.
struct XcodeSettingContext: Equatable {
    let sdk: String
    let configuration: String
    /// Every triple the emitter writes is `arm64`.
    var architecture = "arm64"
    /// Xcode's default build variant; a project that builds `profile` or `debug` variants
    /// asks for them by name.
    var variant = "normal"
}

/// `KEY = value`, or `KEY[sdk=macosx*][config=Debug] = value`: one assignment of a
/// setting, from an xcconfig line or from a configuration's `buildSettings`.
struct XcodeSettingAssignment: Equatable {
    let name: String
    let conditions: [XcodeSettingCondition]
    let value: String

    init(name: String, conditions: [XcodeSettingCondition] = [], value: String) {
        self.name       = name
        self.conditions = conditions
        self.value      = value
    }

    /// Reads a key with its conditions, each in brackets of its own —
    /// `KEY[sdk=iphoneos*][arch=arm64]` — or several in one, comma-separated —
    /// `KEY[sdk=iphoneos*,arch=arm64]`; Xcode accepts both. Nil for a key that is not a
    /// setting name, or whose brackets do not close: Xcode refuses such a line, and a
    /// guess at what it meant would be a setting nobody wrote.
    init?(key: String, value: String) {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        let nameEnd = trimmed.firstIndex(of: "[") ?? trimmed.endIndex
        let name = String(trimmed[..<nameEnd])
        guard Self.isSettingName(name) else {
            return nil
        }
        var conditions: [XcodeSettingCondition] = []
        var rest = trimmed[nameEnd...]
        while !rest.isEmpty {
            guard rest.first == "[", let close = rest.firstIndex(of: "]") else {
                return nil
            }
            for clause in rest[rest.index(after: rest.startIndex)..<close].split(separator: ",") {
                guard let equals = clause.firstIndex(of: "=") else {
                    return nil
                }
                conditions.append(XcodeSettingCondition(
                    parameter: clause[..<equals].trimmingCharacters(in: .whitespaces),
                    pattern:   clause[clause.index(after: equals)...].trimmingCharacters(in: .whitespaces)))
            }
            rest = rest[rest.index(after: close)...]
        }
        self.init(name: name, conditions: conditions, value: value)
    }

    func applies(in context: XcodeSettingContext) -> Bool {
        conditions.allSatisfy { $0.holds(in: context) }
    }

    private static func isSettingName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || CharacterSet.letters.contains(first) else {
            return false
        }
        return name.unicodeScalars.allSatisfy { $0 == "_" || CharacterSet.alphanumerics.contains($0) }
    }
}

// MARK: - A file

/// One `.xcconfig`, parsed, its includes not yet followed.
struct Xcconfig: Equatable {

    enum Line: Equatable {
        case assignment(XcodeSettingAssignment)
        /// `#include "path"`, or `#include? "path"`, which may name a file that is not
        /// there — NetNewsWire's hook for a developer's own signing settings, outside the
        /// clone. The path is as written.
        case include(path: String, isOptional: Bool)
    }

    let lines: [Line]

    /// `//` starts a comment anywhere on a line, a value included: Xcode reads it so, which
    /// is why a URL in an xcconfig is written `https:/$()/`. A trailing `;` is dropped, as
    /// Xcode drops it — NetNewsWire writes `SDKROOT = macosx;`, and `macosx;` names no SDK.
    /// A line that is neither an include nor an assignment is skipped.
    init(parsing text: String) {
        var lines: [Line] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let uncommented = rawLine.components(separatedBy: "//").first ?? ""
            let line = uncommented.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                if let include = Self.include(line) {
                    lines.append(include)
                }
                continue
            }
            guard let equals = Self.assignmentOperator(in: line) else {
                continue
            }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasSuffix(";") {
                value = String(value.dropLast()).trimmingCharacters(in: .whitespaces)
            }
            if let assignment = XcodeSettingAssignment(key: String(line[..<equals]), value: value) {
                lines.append(.assignment(assignment))
            }
        }
        self.lines = lines
    }

    /// The first `=` outside the brackets of a condition, which holds `=` of its own:
    /// `CODE_SIGN_IDENTITY[sdk=macosx*] = Mac Developer`.
    private static func assignmentOperator(in line: String) -> String.Index? {
        var depth = 0
        for index in line.indices {
            switch line[index] {
            case "[":
                depth += 1
            case "]":
                depth -= 1
            case "=" where depth == 0:
                return index
            default:
                continue
            }
        }
        return nil
    }

    /// `#include "path"` and `#include? "path"`; the path is taken from between the quotes,
    /// or as the rest of the line when there are none.
    private static func include(_ line: String) -> Line? {
        let optionalDirective = "#include?"
        let directive = "#include"
        let isOptional = line.hasPrefix(optionalDirective)
        guard isOptional || line.hasPrefix(directive) else {
            return nil
        }
        let argument = line.dropFirst(isOptional ? optionalDirective.count : directive.count).trimmingCharacters(in: .whitespaces)
        let path = argument.hasPrefix("\"") && argument.dropFirst().contains("\"")
            ? String(argument.dropFirst().prefix { $0 != "\"" })
            : argument
        guard !path.isEmpty else {
            return nil
        }
        return .include(path: path, isOptional: isOptional)
    }
}

// MARK: - Includes followed

/// What a reader of xcconfig files knows of one it has asked for.
enum XcconfigFile: Equatable {
    /// Asked for and not answered yet: the converter's `StaticFile` has not been processed.
    case pending
    /// Not there: a path nobody pushed, or outside the file system the build reads.
    case absent
    case present(Xcconfig)
}

/// An xcconfig with its includes followed, depth first, each included file's assignments
/// spliced in at the line that names it: one list, in the order Xcode reads it, for
/// `XcodeBuildSettings` to evaluate as one level.
///
/// Paths are relative to the project's folder, and may climb out of it —
/// `../SharedXcodeSettings/ProjectSettings.xcconfig` is where NetNewsWire looks for a
/// developer's own file — so the two readers can each map them onto their own file system.
/// An include is looked for beside the file that names it, and then under the project's
/// folder, which is where Xcode looks when the first place has nothing.
struct XcconfigExpansion: Equatable {

    /// Every file the expansion looked for, in the order it looked: the files it read,
    /// the includes it is waiting on, and the places an include was not. What the
    /// converter demands.
    private(set) var files: [String] = []
    /// The assignments, in the order Xcode reads them.
    private(set) var assignments: [XcodeSettingAssignment] = []
    /// Some file has not been answered yet; the assignments are incomplete.
    private(set) var isWaiting = false
    /// The files that should be there and are not: the root, or a file a plain
    /// `#include` names, by the first place it was looked for. The level is read without
    /// them, the way a missing root has always been read — as though empty — and the
    /// converter names them as the cause of whatever that leaves undefined.
    private(set) var missing: [String] = []

    enum Failure: Error, Equatable, CustomStringConvertible {
        /// An include that leads back to a file it is inside of; Xcode refuses it too.
        case includeCycle([String])

        var description: String {
            switch self {
            case .includeCycle(let chain):
                return "xcconfig files include each other in a cycle: \(chain.joined(separator: " → "))"
            }
        }
    }

    init(root: String, file: (String) -> XcconfigFile) throws {
        let root = Self.normalized(root)
        files.append(root)
        switch file(root) {
        case .pending:
            isWaiting = true
        case .absent:
            missing.append(root)
        case .present(let xcconfig):
            try expand(xcconfig, at: root, chain: [root], file: file)
        }
    }

    private mutating func expand(_ xcconfig: Xcconfig, at path: String, chain: [String],
                                 file: (String) -> XcconfigFile) throws {
        for line in xcconfig.lines {
            switch line {
            case .assignment(let assignment):
                assignments.append(assignment)
            case .include(let includePath, let isOptional):
                // Past an include still pending, too: the assignments are thrown away
                // on a waiting pass, but the includes further down are found, so every
                // file one level deep is demanded in the same pass.
                try include(includePath, isOptional: isOptional, from: path, chain: chain, file: file)
            }
        }
    }

    private mutating func include(_ includePath: String, isOptional: Bool, from includer: String, chain: [String],
                                  file: (String) -> XcconfigFile) throws {
        let candidates = Self.candidates(for: includePath, from: includer)
        for candidate in candidates {
            guard !chain.contains(candidate) else {
                throw Failure.includeCycle(chain + [candidate])
            }
            if !files.contains(candidate) {
                files.append(candidate)
            }
            switch file(candidate) {
            case .pending:
                isWaiting = true
                return
            case .absent:
                continue
            case .present(let included):
                try expand(included, at: candidate, chain: chain + [candidate], file: file)
                return
            }
        }
        if !isOptional, let first = candidates.first {
            missing.append(first)
        }
    }

    /// Beside the including file first, then under the project's folder; one place for an
    /// absolute path.
    static func candidates(for includePath: String, from includer: String) -> [String] {
        guard !includePath.hasPrefix("/") else {
            return [normalized(includePath)]
        }
        let folder = includer.split(separator: "/", omittingEmptySubsequences: false).dropLast().joined(separator: "/")
        let beside = normalized(folder.isEmpty ? includePath : "\(folder)/\(includePath)")
        let underProject = normalized(includePath)
        return beside == underProject ? [beside] : [beside, underProject]
    }

    /// `.` dropped and `..` taking away the segment before it, lexically; a `..` with
    /// nothing before it to take away stays, so a path may climb out of the project's
    /// folder and the reader decides whether that is still somewhere it can read.
    static func normalized(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        var segments: [String] = []
        for segment in path.split(separator: "/") {
            switch segment {
            case ".":
                continue
            case "..":
                if let last = segments.last, last != ".." {
                    segments.removeLast()
                } else if !isAbsolute {
                    segments.append("..")
                }
            default:
                segments.append(String(segment))
            }
        }
        return (isAbsolute ? "/" : "") + segments.joined(separator: "/")
    }
}
