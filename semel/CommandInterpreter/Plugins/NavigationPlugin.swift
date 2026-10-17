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

    /// One `list` request, its streamed parts gathered: what the monitor's products window
    /// lists through too (`CommandInterpreter.outputFolders`).
    private func list(_ pattern: Path, in fileSystem: FileSystemForCommand,
                      context: any CommandContext) throws -> [ListEntry] {
        try context.listEntries(pattern, in: fileSystem.kind)
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

        let rows = ListingOrder.sorted(results).map { entry in
            ListingRow(entry: entry,
                       name: context.relativeName(Path(entry.path), to: displayBase) + (entry.kind == .folder ? "/" : ""),
                       note: ValueState.listingNote(for: entry.status, kind: entry.kind, in: targetFS.kind).map { "[\($0)]" })
        }
        Self.listingLines(rows).forEach { context.outputMessage($0) }
    }

    /// One line of a listing before it is laid out: the entry, its name as printed — a
    /// folder's with its separator — and its state's note, bracketed, if it has one.
    struct ListingRow {
        let entry: ListEntry
        let name:  String
        let note:  String?
    }

    /// The lines of a listing: mode, size and name, then each note right-aligned to one
    /// column, the one the longest noted name and the longest note reach, so names of
    /// different lengths do not stagger the notes. A line with no note ends at its name and
    /// moves no column: a long folder name above would otherwise push every note away.
    static func listingLines(_ rows: [ListingRow]) -> [String] {
        let nameWidth = rows.filter { $0.note != nil }.map(\.name.count).max() ?? 0
        let noteWidth = rows.compactMap { $0.note?.count }.max() ?? 0
        return rows.map { row in
            let modeText = row.entry.kind == .folder
                ? modeString(0, isDirectory: true)
                : modeString(row.entry.mode ?? 0)
            let sizeText = row.entry.kind == .folder
                ? noSize
                : row.entry.size.map { String(format: "%8d", $0) } ?? noSize
            let line = "\(modeText)  \(sizeText)  \(row.name)"
            guard let note = row.note else {
                return line
            }
            let padding = (nameWidth - row.name.count) + (noteWidth - note.count)
            return line + String(repeating: " ", count: padding + 2) + note
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
