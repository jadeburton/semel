// NavigationPlugin.swift
// build_system
//
// Handles: cd, pwd, ls / list

import BuildSystemCore
import Foundation

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

    // MARK: - cd

    private func handleCd(folder: FileSystemForCommand?, path: String?,
                           context: any CommandContext) throws {
        if let folder {
            context.currentFileSystem = folder
            context.currentDirectoryPath = .empty
        }

        if let path, !path.isEmpty {
            let newPath = context.resolve(path, relativeTo: context.currentDirectoryPath)
            if !newPath.isEmpty {
                let fs = try context.fileSystem(for: context.currentFileSystem)
                guard let node = try fs.childNode(path: newPath), node.kind == Folder.kind else {
                    context.outputError("cd: \(path): no such directory"); return
                }
            }
            context.currentDirectoryPath = newPath
        }

        context.outputMessage(context.currentLocation)
    }

    // MARK: - ls

    private func handleList(folder: FileSystemForCommand?, pathOrWildcard: String?,
                             context: any CommandContext) throws {
        let targetFS = folder ?? context.currentFileSystem
        let base: Path = folder != nil ? .empty : context.currentDirectoryPath

        let fileSystem = try context.fileSystem(for: targetFS)
        let matcher    = FileWildcardMatcher(input: InternalFileSystemLister(folder: fileSystem))

        let results: [FileWildcardEntry]
        let displayBase: Path

        if let p = pathOrWildcard {
            let fullPattern = base.isEmpty ? Path(p) : base / p

            if fullPattern.containsWildcard {
                let staticSegs = fullPattern.segments.prefix(while: {
                    !$0.contains("*") && !$0.contains("?") && $0 != "**"
                })
                displayBase = Path(segments: Array(staticSegs))
                results = try matcher.findAllMatching(pathOrWildcard: fullPattern)
            } else {
                let initial = try matcher.findAllMatching(pathOrWildcard: fullPattern)
                if initial.count == 1, initial[0].kind == .folder {
                    displayBase = initial[0].path
                    results = try matcher.findAllMatching(pathOrWildcard: displayBase / "*")
                } else {
                    displayBase = fullPattern.deletingLastComponent.map { Path(segments: $0.segments) } ?? .empty
                    results = initial
                }
            }
        } else {
            let pattern = base.isEmpty ? Path("*") : base / "*"
            displayBase = base
            results = try matcher.findAllMatching(pathOrWildcard: pattern)
        }

        if results.isEmpty { context.outputMessage("(empty)"); return }

        let sorted = results.sorted {
            if $0.kind != $1.kind { return $0.kind == .folder }
            return $0.path.string.lowercased() < $1.path.string.lowercased()
        }

        for entry in sorted {
            let name   = context.relativeName(entry.path, to: displayBase)
            let suffix = entry.kind == .folder ? "/" : ""
            let note   = entry.isMissing ? " [missing]" : entry.isUnreferenced ? " [?]" : ""
            context.outputMessage("\(name)\(suffix)\(note)")
        }
    }
}
