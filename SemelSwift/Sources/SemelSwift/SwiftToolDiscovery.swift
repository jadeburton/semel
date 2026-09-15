// SwiftToolDiscovery.swift
// SemelSwift
//
// Where the Swift tools are on this machine and what version they report — what this
// package declares to `ToolDiscovery` when it registers.

import Foundation
import SemelNodeKit

enum SwiftToolDiscovery {

    /// The tools this package runs, each located through the active toolchain.
    static var finders: [ToolFinder] {
        ["swiftc", "swift"].map { name in
            ToolFinder(name: name, locate: { locate(name) }, version: version(ofToolAt:))
        }
    }

    /// Absolute path to `toolName` in the active toolchain, via `xcrun --find`, or nil if
    /// there is no such tool.
    static func locate(_ toolName: String) -> String? {
        guard let path = xcrun(["--find", toolName]),
              FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return path
    }

    /// The version the Swift tool at `path` reports, or nil if it reports nothing
    /// recognisable.
    static func version(ofToolAt path: String) -> String? {
        MachineQuery.output(of: path, ["--version"]).flatMap(parseVersion(from:))
    }

    /// The tool's own version out of its `--version` output: the `Apple Swift version
    /// <number>` string, with the parenthesised build identifier when the tool reports
    /// one. `swiftc` leads with its driver version, which is not the tool's version and
    /// is skipped.
    ///
    /// The build identifier is kept deliberately. This string ends up in a ToolDescriptor,
    /// which keys the build cache, and two compilers sharing a marketing version with
    /// different build identifiers are different binaries that can produce different
    /// output.
    static func parseVersion(from output: String) -> String? {
        let pattern = #"Apple Swift version [0-9]+(\.[0-9]+)*( \([^)]*\))?"#
        return output.range(of: pattern, options: .regularExpression).map { String(output[$0]) }
    }
}
