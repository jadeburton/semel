// CommandContext.swift
// build_system

import BuildSystemCore
import Foundation
import SemelNodeKit

protocol CommandContext: AnyObject {
    var database: DatabaseLayer { get }
    var baseDirectory: String { get set }
    var currentFileSystem: FileSystemForCommand { get set }
    var currentDirectoryPath: Path { get set }
    var inputFileSystem: Node { get throws }
    var outputFileSystem: Node { get throws }
    var buildEngine: BuildEngine { get }
    func outputMessage(_ message: String)
    func outputError(_ message: String)
}

extension CommandContext {
    var currentLocation: String {
        let fsName = currentFileSystem == .input ? Folder.inputFileSystemName : Folder.outputFileSystemName
        return currentDirectoryPath.isEmpty ? fsName : "\(fsName)/\(currentDirectoryPath)"
    }

    func fileSystem(for target: FileSystemForCommand) throws -> Node {
        switch target {
        case .input:  return try inputFileSystem
        case .output: return try outputFileSystem
        }
    }

    /// Resolves a user-supplied path string relative to `base`, handling `..` and `.`.
    /// A leading `/` is treated as the root of the current internal file system.
    func resolve(_ pathStr: String, relativeTo base: Path) -> Path {
        let isAbsolute = pathStr.hasPrefix("/")
        var segments = isAbsolute ? [] : base.segments
        for seg in Path(isAbsolute ? String(pathStr.dropFirst()) : pathStr).segments {
            switch seg {
            case "..": if !segments.isEmpty { segments.removeLast() }
            case ".":  break
            default:   segments.append(seg)
            }
        }
        return Path(segments: segments)
    }

    /// Returns the portion of `path` after `base`, falling back to the full path string.
    func relativeName(_ path: Path, to base: Path) -> String {
        path.relative(to: base)?.string ?? path.string
    }
}

// MARK: - CommandPlugin

protocol CommandPlugin {
    /// The verb strings this plugin handles (e.g. `["ls", "list"]`).
    var verbs: Set<String> { get }

    /// Parse `tokens` (everything after the verb) and execute the command.
    func handle(verb: String, tokens: [String], context: any CommandContext) throws
}

extension CommandPlugin {
    /// Consume a required `-i`/`-o` flag. Defaults to `.input` when absent.
    func parseFileSystemFlag(tokens: [String]) -> (FileSystemForCommand, [String]) {
        guard let first = tokens.first else { return (.input, tokens) }
        switch first {
        case "-i", "--input":  return (.input,  Array(tokens.dropFirst()))
        case "-o", "--output": return (.output, Array(tokens.dropFirst()))
        default:               return (.input,  tokens)
        }
    }

    /// Consume an optional `-i`/`-o` flag, returning `nil` when absent so callers
    /// can distinguish an explicit choice from "use current file system".
    func parseOptionalFileSystemFlag(tokens: [String]) -> (FileSystemForCommand?, [String]) {
        guard let first = tokens.first else { return (nil, tokens) }
        switch first {
        case "-i", "--input":  return (.input,  Array(tokens.dropFirst()))
        case "-o", "--output": return (.output, Array(tokens.dropFirst()))
        default:               return (nil,     tokens)
        }
    }
}
