// ErrorDocument.swift
// SemelNodeKit
//
// What a failing node publishes: a typed value, interned like a `TreeManifest`, carried on
// its ports by `NoValueReason.error` as the hash of its encoding.
//
// A report of a failure has three things to say and the engine knows each as a value: the
// diagnostic — what the tool wrote, or the engine's condition — what the failing function
// belongs to, and, where the engine can state one as a fact, what to change. A document
// keeps them apart so that the client renders every line from values it can switch over,
// and reads no sentence the engine composed (the 2026-10-09 error report design).
//
// A document is a value like any other output: the same failing inputs publish the same
// document, it is cached with the node's other outputs, and two are compared by content.

import Foundation
import SemelDatabaseModels

public struct ErrorDocument: PolySerializable, Hashable, Sendable {
    public static let kind: UInt = 44

    /// What the failing function says about itself.
    public enum Diagnostic: Codable, Hashable, Sendable {
        /// What a tool printed, as it printed it: the text a person reads and a terminal
        /// makes a link of, with the name of the tool that printed it.
        case tool(text: String, tool: String)
        /// A condition of the engine or a node, rendered by the client.
        case engine(ErrorCondition)
        /// A node with several causes — a converter missing three packages — publishes them
        /// as one document, and a report shows each as its own block. Never nested and
        /// never of one: `ErrorDocument.several` flattens and unwraps.
        case several([ErrorDocument])
    }

    /// What the failing function belongs to, with the kind of thing that is. The node knows
    /// it: `SwiftCompiler` the module, `SwiftLinker` the product, the lock check the
    /// package.
    public enum Subject: Codable, Hashable, Sendable {
        /// A module a compile builds: `Models`.
        case target(name: String)
        /// A product, by its path in the output file system or by the file it names.
        case product(path: String)
        /// A package, by name: `GRDB.swift`.
        case package(name: String)
        /// A resource a node compiles, by its path: an asset or string catalog, a nib.
        case resource(path: String)
        /// The formula a builder or a converter reads, by its path in the input file system.
        case formula(path: String)
        /// The Xcode project a converter reads.
        case project(path: String)
        /// One source a node compiles or preprocesses, by its path in the input file system.
        case source(path: String)

        /// The kind alone, which is what a report merges blocks by: eight compilers missing
        /// one setting are one block naming eight sources.
        public enum Kind: String, Codable, Hashable, Sendable {
            case target, product, package, resource, formula, project, source
        }

        public var kind: Kind {
            switch self {
            case .target:   return .target
            case .product:  return .product
            case .package:  return .package
            case .resource: return .resource
            case .formula:  return .formula
            case .project:  return .project
            case .source:   return .source
            }
        }
    }

    /// What to change, as a fact — never advice. Only the conditions that have one the
    /// engine can name carry it.
    public enum Remedy: Codable, Hashable, Sendable {
        /// A vendored package whose lock does not match: `semel-swift prepare` re-locks it.
        case relock(package: String)
        /// A target folder in none of the places looked: the folders tried, in order.
        case missingFolder(tried: [String])
        /// The settings behind the arguments the tool complained about, by key.
        case setting(keys: [String])
        /// A node row whose kind no linked type has.
        case register(kind: UInt)
        /// A name no linked type has.
        case registerType(name: String)
        /// The commands outside Semel that write the machine file a node needs (B-109).
        case writeMachineFile(commands: [MachineFileCommand])
        /// Dependencies nobody vendored: `semel-swift prepare` copies them in.
        case vendor
        /// A stored object whose bytes are not the ones it is filed under: deleting the
        /// file makes it rebuild.
        case delete(path: String)
    }

    public let diagnostic: Diagnostic
    /// Nil for a condition about the graph rather than about one thing in it — a source
    /// nobody pushed is named by its path on the diagnostic's own line.
    public let subject:    Subject?
    public let remedy:     Remedy?

    public init(diagnostic: Diagnostic, subject: Subject?, remedy: Remedy?) {
        self.diagnostic = diagnostic
        self.subject    = subject
        self.remedy     = remedy
    }
}

/// A command that writes the machine file, with the folder it writes into when the report
/// knows it — the folder the file a formula names sits in — and the flags that make it
/// replace what it wrote before, for a tool that file names and this machine no longer has.
public struct MachineFileCommand: Codable, Hashable, Sendable {
    public let command: String
    /// Relative to the input file system's root, `.` for the root; nil when unknown.
    public let folder:  String?
    public let flags:   [String]

    public init(command: String, folder: String?, flags: [String] = []) {
        self.command = command
        self.folder  = folder
        self.flags   = flags
    }

    public init(writer: MachineFileWriter, folder: String?, rewriting: Bool = false) {
        self.init(command: writer.command, folder: folder, flags: rewriting ? writer.rewriteFlags : [])
    }
}

// MARK: - Making one

extension ErrorDocument {

    /// A tool's failure: what it printed, or the condition of a tool that printed nothing.
    /// `settings` are the arguments the node built from settings; each one the output
    /// complains about is named as the remedy, so a rejected `-target` reads as a key to
    /// set rather than a triple nobody typed.
    public static func tool(text: String, tool: String, status: Int32, subject: Subject?,
                            settings: [SettingArgument] = []) -> ErrorDocument {
        let printed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !printed.isEmpty else {
            return engine(.toolExitedSilently(tool: tool, status: status), subject: subject)
        }
        let keys = SettingArgument.keys(for: settings, matching: printed)
        return ErrorDocument(diagnostic: .tool(text: printed, tool: tool),
                             subject:    subject,
                             remedy:     keys.isEmpty ? nil : .setting(keys: keys))
    }

    /// An engine condition, with the remedy it implies unless one is given.
    public static func engine(_ condition: ErrorCondition, subject: Subject?,
                              remedy: Remedy? = nil) -> ErrorDocument {
        ErrorDocument(diagnostic: .engine(condition), subject: subject, remedy: remedy ?? condition.impliedRemedy)
    }

    /// Several causes as one document, or the one cause itself. Nil for none.
    public static func several(_ documents: [ErrorDocument]) -> ErrorDocument? {
        let causes = documents.flatMap(\.causes)
        guard causes.count != 1 else {
            return causes.first
        }
        guard !causes.isEmpty else {
            return nil
        }
        return ErrorDocument(diagnostic: .several(causes), subject: nil, remedy: nil)
    }

    /// The document, or each of the several it holds: what a report shows as blocks.
    public var causes: [ErrorDocument] {
        guard case .several(let documents) = diagnostic else {
            return [self]
        }
        return documents.flatMap(\.causes)
    }

    /// The state a port carries for this document: interned, its hash on the reason.
    public func published() throws -> NodeValue {
        .noValue(reason: try asReason())
    }

    public func asReason() throws -> NoValueReason {
        .error(documentHash: try toJSON().intern())
    }

    /// The document an error port's hash names, or nil when the object store does not hold
    /// one — an empty hash, a document the store has lost.
    public static func read(documentHash: DataObjectHash) -> ErrorDocument? {
        guard !documentHash.isEmpty, let json = try? documentHash.resolveAsString() else {
            return nil
        }
        return try? TypeRegistry.decodeAndCast(encodedJSON: json)
    }

    /// The document a thrown error stands for: its condition when it names one, and the
    /// last resort when it does not.
    public static func thrown(_ error: Error, subject: Subject?) -> ErrorDocument {
        engine(condition(of: error), subject: subject)
    }

    /// The condition a thrown error names.
    public static func condition(of error: Error) -> ErrorCondition {
        if let convertible = error as? ErrorConditionConvertible {
            return convertible.errorCondition
        }
        return .unclassified(type: String(describing: type(of: error)), description: "\(error)")
    }
}

// MARK: - What a report merges and counts

extension ErrorDocument {

    /// What makes two blocks of a report one: the diagnostic and the remedy, and the kind
    /// of subject without which one it is. Eight compilers missing one machine setting are
    /// one error naming eight sources, not eight. The engine counts by it and the client
    /// merges by it, so the settle's count and the report's agree.
    public struct MergeKey: Hashable, Sendable {
        public let diagnostic:  Diagnostic
        public let subjectKind: Subject.Kind?
        public let remedy:      Remedy?
    }

    public var mergeKey: MergeKey {
        MergeKey(diagnostic: diagnostic, subjectKind: subject?.kind, remedy: remedy)
    }

    /// The source nobody has pushed that this document names, as `push` takes it — relative
    /// to the input file system, without its root — or nil. What `build` follows: a
    /// typed path, so a client acts on it without reading a sentence (B-110).
    public var unpushedSource: String? {
        guard case .engine(.notPushed(let path, _)) = diagnostic else {
            return nil
        }
        let full = Path(path)
        return (full.relative(to: Path(FileSystemName.input)) ?? full).string
    }
}

// MARK: - Nodes

extension SimplifiedToolExecuteResult {

    /// What the tool printed on either stream, the error stream first. Both, because tools
    /// differ in where their diagnostics go — actool under `--output-format
    /// human-readable-text` writes them to stdout.
    public var printedOutput: String {
        [errorOutput, infoOutput]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The document for a failed run: what the tool printed, under `subject`.
    public func failureDocument(tool: String, subject: ErrorDocument.Subject?,
                                settings: [SettingArgument] = []) -> ErrorDocument {
        .tool(text: printedOutput, tool: tool, status: exitCode, subject: subject, settings: settings)
    }

    /// The document for a clean run that wrote none of `paths`.
    public func wroteNothingDocument(tool: String, paths: [String], subject: ErrorDocument.Subject?) -> ErrorDocument {
        .engine(.toolWroteNothing(tool: tool, status: exitCode, paths: paths), subject: subject)
    }
}

extension ProcessInput {
    /// One setting from the settings wired to `port`, best effort, for a node naming what
    /// its failure belongs to: a compile's module, a link's product. Nil when the settings
    /// have no value or no such key — a report leaves the subject out rather than fail.
    public func reportedSetting(_ key: String, onPort port: String) -> String? {
        guard let wires = inputValues[port], wires.count == 1,
              case .value(let hash)? = wires.first?.value,
              let text = try? hash.resolveAsString() else {
            return nil
        }
        return [String: String](plainText: text)[key]
    }
}
