// OutputListing.swift
// semel
//
// `output:` as `ls` lists it, folder by folder, for a program that shows the products
// rather than printing them: the monitor's products window (B-150). One streamed `list`
// request gathers the whole tree, and each folder's entries come out in the order `ls`
// prints them, through the same ordering `ls` uses, so the window and the prompt cannot
// disagree about what a folder holds.

import Foundation
import SemelNodeKit
import SemelProtocol

/// One folder of `output:` and what `ls -o <folder>` lists in it.
public struct FolderListing: Equatable, Sendable {
    /// Below the root of `output:`, as `c` or `App/Frameworks`; empty for the root itself.
    public let folder: String
    /// The folder's own entries — its subfolders and its products — in `ls` order.
    public let entries: [ListEntry]

    public init(folder: String, entries: [ListEntry]) {
        self.folder  = folder
        self.entries = entries
    }
}

/// The order `ls` prints a folder's entries in: folders first, then by path, ignoring case.
public enum ListingOrder {
    public static func sorted(_ entries: [ListEntry]) -> [ListEntry] {
        entries.sorted {
            if $0.kind != $1.kind { return $0.kind == .folder }
            return $0.path.lowercased() < $1.path.lowercased()
        }
    }
}

extension CommandContext {

    /// Every entry a `list` of `pattern` matches, gathered part by part as the reply streams
    /// (B-137), so a tree of any size is never one frame.
    func listEntries(_ pattern: Path, in fileSystem: FileSystemKind) throws -> [ListEntry] {
        var entries: [ListEntry] = []
        let last = try request(.list(fileSystem: fileSystem, pattern: pattern.string)) { part in
            if case .list(let partEntries) = part {
                entries.append(contentsOf: partEntries)
            }
        }.0
        if case .list(let lastEntries) = last {
            entries.append(contentsOf: lastEntries)
        }
        return entries
    }
}

extension CommandInterpreter {

    /// Every folder of `output:`, the root first and the rest in path order ignoring case,
    /// each with its entries as `ls -o <folder>` lists them. The root is always there, even
    /// with nothing built: `ls -o` answers for it too.
    public func outputFolders() throws -> [FolderListing] {
        let everything = try listEntries(Path(WildcardPath.anyFolders) / "*", in: .output)
        var byFolder: [String: [ListEntry]] = ["": []]
        for entry in everything {
            let parent = Path(entry.path).deletingLastComponent?.string ?? ""
            byFolder[parent, default: []].append(entry)
            if entry.kind == .folder, byFolder[entry.path] == nil {
                byFolder[entry.path] = []
            }
        }
        return byFolder.keys
            .sorted { ($0.isEmpty ? 0 : 1, $0.lowercased()) < ($1.isEmpty ? 0 : 1, $1.lowercased()) }
            .map { FolderListing(folder: $0, entries: ListingOrder.sorted(byFolder[$0] ?? [])) }
    }

    /// `export <folder> --into <destination>`, through the code that command runs, for the
    /// products of `selecting` alone when it is given: paths below the root of `output:`,
    /// each a product or a folder whose products all go. Each is written where `export
    /// <folder>` writes it, at its place below the folder. Answers how many files were
    /// written, nil when there was nothing to export; what went wrong on the way is printed
    /// through `output`, as the command prints it.
    public func export(folder: String, selecting selection: Set<String>?, into destination: String) throws -> Int? {
        try FilePlugin.exportFiles(folderToken: folder.isEmpty ? "." : folder, destination: destination,
                                   skippingWithoutValue: false, selecting: selection, context: self)
    }
}
