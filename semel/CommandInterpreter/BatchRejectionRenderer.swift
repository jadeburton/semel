// BatchRejectionRenderer.swift
// semel
//
// How a client says that the lock barrier refused a batch (B-146): what the batch was
// refused for, then one labelled line per fact — the lock, the root it records, the root
// the batch would have left, the paths that moved it — and what to do about it. The shape
// of every report this client prints: a statement, and label and value lines under it.

import Foundation
import SemelNodeKit
import SemelProtocol

enum BatchRejectionRenderer {

    /// How many paths the report names before it counts the rest.
    static let pathsNamed = 10

    static func lines(folder: String, lock: String, expected: LockExpectation, found: String?,
                      paths: [String]) -> [String] {
        let folderName = "\(FileSystemName.input)/\(folder)"
        var lines = ["\(folderName) is locked, and the batch changed it without a lock it matches: "
                     + "the batch was not committed, \(FileSystemName.input) is as it was before it, and no batch is open."]
        lines.append(labelled("lock:", "\(FileSystemName.input)/\(lock)"))
        lines.append(labelled("expected:", describe(expected)))
        lines.append(labelled("found:", found.map { DependencyLock.contentScheme + $0 } ?? "no folder"))
        let shown = paths.prefix(pathsNamed).map { "\(FileSystemName.input)/\($0)" }
        for (index, path) in shown.enumerated() {
            lines.append(labelled(index == 0 ? "paths:" : "", path))
        }
        if paths.count > pathsNamed {
            lines.append(labelled("", "and \(paths.count - pathsNamed) more"))
        }
        lines.append("  `semel-swift prepare` vendors the folder again and writes its lock with it; "
                     + "removing the lock unlocks the folder.")
        return lines
    }

    /// `  lock:     input:/…`, the values in one column.
    private static func labelled(_ label: String, _ value: String) -> String {
        let column = "expected: ".count
        return "  " + label.padding(toLength: column, withPad: " ", startingAt: 0) + value
    }

    private static func describe(_ expected: LockExpectation) -> String {
        switch expected {
        case .contentRoot(let root):
            return DependencyLock.contentScheme + root
        case .otherFold(let fold, let root):
            return "\(DependencyLock.contentScheme)\(root), folded as '\(fold)', which this Semel does not fold "
                 + "('\(FolderContentRoot.formatTag)')"
        case .unreadable(_, let problem):
            return "nothing that can be read: \(problem)"
        }
    }
}
