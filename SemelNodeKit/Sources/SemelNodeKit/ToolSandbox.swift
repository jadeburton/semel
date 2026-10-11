//
//  ToolSandbox.swift
//  SemelNodeKit
//
//  What a tool is allowed to know about the directory it runs in.
//

import Foundation

/// The contract every `ToolRunner` keeps with the nodes that call it.
///
/// A tool runs in a fresh directory of its own, with its inputs materialised below that
/// directory at their wire keys — an input-file-system path such as `input:/c/src/hello.c`
/// — and with that directory as its working directory. Every path a node puts on a
/// command line is relative to it. The directory's real name is therefore never on a
/// command line and never in an output, so a tool run at a different mount, or on a
/// different machine, writes the same bytes.
///
/// Where a tool insists on recording a directory name anyway — a compiler's debug
/// information records the compilation directory — the nodes tell it this name instead.
public enum ToolSandbox {

    /// The name a tool is told the sandbox root is called, so that a path it records
    /// names the build rather than the directory this run happened to get. Never a real
    /// directory: nothing resolves it, nothing creates it, and the tool never opens it.
    public static let canonicalRootName = "/semel"

    /// A folder below the root for state a tool derives from its inputs while it runs — a
    /// clang module cache — named relative to the root like every other path. It is never
    /// an input and never an output, and it goes with the sandbox, so what one run builds
    /// there cannot reach another run's result. A name no wire key takes: every input sits
    /// below a file-system name such as `input:`, and no node names an output this way.
    public static let derivedStateFolderName = ".semel-derived"

    /// Whether `bytes` name the folder a run had, `sandboxPath`, by either of the names
    /// macOS gives a temporary folder (`/private/var/…` and `/var/…`): what a node checks the
    /// output of a tool it publishes as written, since such an output would be a different
    /// value on every run. Searched as bytes: an output may hold any byte, and a path in a
    /// binary file is still a path.
    public static func names(sandboxPath: String, in bytes: [UInt8]) -> Bool {
        guard !sandboxPath.isEmpty else {
            return false
        }
        let unprivate = sandboxPath.hasPrefix("/private/") ? String(sandboxPath.dropFirst("/private".count)) : sandboxPath
        return [sandboxPath, unprivate].contains { contains(bytes, Array($0.utf8)) }
    }

    private static func contains(_ bytes: [UInt8], _ needle: [UInt8]) -> Bool {
        guard let first = needle.first, needle.count <= bytes.count else {
            return false
        }
        var index = 0
        let last = bytes.count - needle.count
        while index <= last {
            if bytes[index] == first, bytes[index..<(index + needle.count)].elementsEqual(needle) {
                return true
            }
            index += 1
        }
        return false
    }
}
