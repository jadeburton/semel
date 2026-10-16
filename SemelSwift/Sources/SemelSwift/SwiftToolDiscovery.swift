// SwiftToolDiscovery.swift
// SemelSwift
//
// Where the Swift tools are on this machine and what version they report — what this
// package declares to `ToolDiscovery` when it registers.

import Foundation
import SemelNodeKit

enum SwiftToolDiscovery {

    /// The tools this package runs, each located through the active toolchain. The
    /// compiler's fingerprint covers the macro plugins it runs beside itself (B-80) and the
    /// binaries it hands work to: the driver, and for a link clang, `ld` and, for a static
    /// library, libtool. The package tool's covers `swift-package`, which `swift package`
    /// runs; it reads a manifest, which expands no macro.
    static var finders: [ToolFinder] {
        [ToolFinder(name: "swiftc", locate: { locate("swiftc") }, version: version(ofToolAt:),
                    companionFingerprint: compilerCompanions(ofToolAt:)),
         ToolFinder(name: "swift", locate: { locate("swift") }, version: version(ofToolAt:),
                    companionFingerprint: { siblingBinariesFingerprint(besideToolAt: $0, named: packageToolHelpers) })]
    }

    /// What swiftc runs from beside itself.
    static let compilerHelpers = ["clang", "ld", "libtool", "swift-driver"]

    /// What `swift package` runs from beside itself.
    static let packageToolHelpers = ["swift-package"]

    /// The plugins' fingerprint and the helpers', each on a line of its own; nil when the
    /// toolchain has neither.
    static func compilerCompanions(ofToolAt path: String) -> String? {
        let parts = [SwiftCompilerPlugins.fingerprint(ofToolAt: path).map { "plugins=\($0)" },
                     siblingBinariesFingerprint(besideToolAt: path, named: compilerHelpers)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
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
