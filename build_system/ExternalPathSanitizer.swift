// ExternalPathSanitizer.swift
// build_system

import Foundation

final class ExternalPathSanitizer {

    /// Expand and canonicalise a path entered by the user:
    /// - `~` → home directory
    /// - relative paths → absolute (resolved against `currentDirectoryPath`)
    /// - `.` / `..` components → standardised
    /// - symlinks → resolved
    static func expandPartialPath(_ path: String) -> String {
        var expanded = path

        if expanded.hasPrefix("~") {
            expanded = (expanded as NSString).expandingTildeInPath
        }

        if !expanded.hasPrefix("/") {
            let cwd = FileManager.default.currentDirectoryPath
            expanded = (cwd as NSString).appendingPathComponent(expanded)
        }

        expanded = (expanded as NSString).standardizingPath
        return  (expanded as NSString).resolvingSymlinksInPath
    }
}
