// ClangToolDiscovery.swift
// SemelClang
//
// Where clang and libtool are on this machine and what version each reports — what this
// package declares to `ToolDiscovery` when it registers.

import Foundation
import SemelNodeKit

enum ClangToolDiscovery {

    /// The compiler, linker and preprocessor are all the clang binary.
    static var finder: ToolFinder {
        ToolFinder(name: "clang", locate: { locate("clang") }, version: version(ofToolAt:))
    }

    /// The archiver runs libtool: clang writes no static archive itself (B-79).
    static var libtoolFinder: ToolFinder {
        ToolFinder(name: "libtool", locate: { locate("libtool") }, version: libtoolVersion(ofToolAt:))
    }

    /// Absolute path to `toolName` in the active toolchain, via `xcrun --find`, or nil if
    /// there is no such tool. Every question this package asks the machine goes through
    /// `MachineQuery`, the one launch-time process runner HermeticityTests allows besides
    /// the sandboxed tool runner.
    static func locate(_ toolName: String) -> String? {
        guard let path = MachineQuery.output(of: "/usr/bin/xcrun", ["--find", toolName]),
              FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return path
    }

    /// The version the clang at `path` reports, or nil if it reports nothing recognisable.
    static func version(ofToolAt path: String) -> String? {
        MachineQuery.output(of: path, ["--version"]).flatMap(parseVersion(from:))
    }

    /// The tool's own version out of its `--version` output: the `Apple clang version
    /// <number>` string, with the parenthesised build identifier when the tool reports one.
    ///
    /// The build identifier is kept deliberately. This string ends up in a ToolDescriptor,
    /// which keys the build cache, and two compilers sharing a marketing version with
    /// different build identifiers are different binaries that can produce different
    /// output.
    static func parseVersion(from output: String) -> String? {
        let pattern = #"Apple clang version [0-9]+(\.[0-9]+)*( \([^)]*\))?"#
        return output.range(of: pattern, options: .regularExpression).map { String(output[$0]) }
    }

    /// The version the libtool at `path` reports, or nil if it reports nothing recognisable.
    static func libtoolVersion(ofToolAt path: String) -> String? {
        MachineQuery.output(of: path, ["-V"]).flatMap(parseLibtoolVersion(from:))
    }

    /// libtool's own version out of its `-V` output, one line of the form `Apple Inc.
    /// version cctools_ld-1267` — the cctools release, which is what tells two libtools
    /// apart, so the whole line is kept.
    static func parseLibtoolVersion(from output: String) -> String? {
        let pattern = #"Apple Inc\. version [^\s]+"#
        return output.range(of: pattern, options: .regularExpression).map { String(output[$0]) }
    }
}
