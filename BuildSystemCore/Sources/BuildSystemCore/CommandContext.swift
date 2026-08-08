// CommandContext.swift
// build_system

import Foundation

// MARK: - CommandContext

protocol CommandContext: AnyObject {
    var database: DatabaseLayer { get }
    var baseDirectory: String? { get set }
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
        let fsName = currentFileSystem == .input ? "inputFileSystem" : "outputFileSystem"
        return currentDirectoryPath.isEmpty ? fsName : "\(fsName)/\(currentDirectoryPath)"
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

    func fileSystem(for target: FileSystemForCommand) throws -> Node {
        switch target {
        case .input:  return try inputFileSystem
        case .output: return try outputFileSystem
        }
    }
}

// MARK: - CommandPlugin

protocol CommandPlugin {
    func handle(_ command: UserCommand, context: any CommandContext) throws -> Bool
}
