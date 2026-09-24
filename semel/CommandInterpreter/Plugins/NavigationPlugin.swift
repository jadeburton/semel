// NavigationPlugin.swift
// semel
//
// Handles: cd, pwd, ls / list

import Foundation
import SemelNodeKit
import SemelProtocol

final class NavigationPlugin: CommandPlugin {

    let verbs: Set<String> = ["cd", "pwd", "ls", "list"]

    func handle(verb: String, tokens: [String], context: any CommandContext) throws {
        switch verb {
        case "cd":
            let (folder, remaining) = parseOptionalFileSystemFlag(tokens: tokens)
            try handleCd(folder: folder, path: remaining.first, context: context)
        case "pwd":
            context.outputMessage(context.currentLocation)
        case "ls", "list":
            let (folder, remaining) = parseOptionalFileSystemFlag(tokens: tokens)
            try handleList(folder: folder, pathOrWildcard: remaining.first, context: context)
        default:
            break
        }
    }

    // MARK: - Listing

    /// One `list` request, unwrapped.
    private func list(_ pattern: Path, in fileSystem: FileSystemForCommand,
                      context: any CommandContext) throws -> [ListEntry] {
        guard case .list(let entries) = try context.request(.list(fileSystem: fileSystem.kind, pattern: pattern.string)).0 else {
            return []
        }
        return entries
    }

    // MARK: - cd

    private func handleCd(folder: FileSystemForCommand?, path: String?,
                          context: any CommandContext) throws {
        if let folder {
            context.currentFileSystem = folder
            context.currentDirectoryPath = .empty
        }

        if let path, !path.isEmpty {
            let newPath = context.resolve(path, relativeTo: context.currentDirectoryPath)

            if newPath.isEmpty {
                context.currentDirectoryPath = .empty
            } else {
                let matches = try list(newPath, in: context.currentFileSystem, context: context)

                guard matches.count == 1, matches[0].kind == .folder else {
                    context.outputError("cd: \(path): no such directory")
                    return
                }
                // The match, not the pattern: `cd sr*` lands on `src`, and `pwd` says so.
                context.currentDirectoryPath = Path(matches[0].path)
            }
        }

        context.outputMessage(context.currentLocation)
    }

    // MARK: - ls

    private func handleList(folder: FileSystemForCommand?, pathOrWildcard: String?,
                            context: any CommandContext) throws {

        let targetFS = folder ?? context.currentFileSystem
        let base: Path = folder != nil ? .empty : context.currentDirectoryPath

        let results: [ListEntry]
        let displayBase: Path

        if let pattern = pathOrWildcard {
            let fullPattern = base.isEmpty ? Path(pattern) : base / pattern

            if fullPattern.containsWildcard {
                let staticSegs = fullPattern.segments.prefix(while: {
                    !$0.contains("*") && !$0.contains("?") && $0 != "**"
                })
                displayBase = Path(segments: Array(staticSegs))
                results = try list(fullPattern, in: targetFS, context: context)
            } else {
                let initial = try list(fullPattern, in: targetFS, context: context)
                if initial.count == 1, initial[0].kind == .folder {
                    displayBase = Path(initial[0].path)
                    results = try list(displayBase / "*", in: targetFS, context: context)
                } else {
                    displayBase = fullPattern.deletingLastComponent.map { Path(segments: $0.segments) } ?? .empty
                    results = initial
                }
            }
        } else {
            let pattern = base.isEmpty ? Path("*") : base / "*"
            displayBase = base
            results = try list(pattern, in: targetFS, context: context)
        }

        if results.isEmpty {
            context.outputMessage("(empty)")
            return
        }

        let sorted = results.sorted {
            if $0.kind != $1.kind { return $0.kind == .folder }
            return $0.path.lowercased() < $1.path.lowercased()
        }

        for entry in sorted {
            let name = context.relativeName(Path(entry.path), to: displayBase)

            var statusNote = ""
            switch entry.status {
            case .none:         break
            case .unreferenced: statusNote = "  [unreferenced]"
            case .pending:      statusNote = "  [pending]"
            case .notProduced:  statusNote = "  [not produced]"
            case .deleted:      statusNote = "  [deleted]"
            case .failed:       statusNote = "  [failed]"
            }

            if entry.kind == .folder {
                context.outputMessage("\(Self.modeString(0, isDirectory: true))  \(Self.noSize)  \(name)/\(statusNote)")
                continue
            }

            let modeStr = Self.modeString(entry.mode ?? 0)
            let sizeStr = entry.size.map { String(format: "%8d", $0) } ?? Self.noSize

            context.outputMessage("\(modeStr)  \(sizeStr)  \(name)\(statusNote)")
        }
    }

    private static let noSize = "       -"

    private static func modeString(_ mode: UInt16, isDirectory: Bool = false) -> String {
        String([
            isDirectory ? Character("d") : Character("-"),
            mode & 0o400 != 0 ? "r" : "-",
            mode & 0o200 != 0 ? "w" : "-",
            mode & 0o100 != 0 ? "x" : "-",
            mode & 0o040 != 0 ? "r" : "-",
            mode & 0o020 != 0 ? "w" : "-",
            mode & 0o010 != 0 ? "x" : "-",
            mode & 0o004 != 0 ? "r" : "-",
            mode & 0o002 != 0 ? "w" : "-",
            mode & 0o001 != 0 ? "x" : "-",
        ] as [Character])
    }
}
