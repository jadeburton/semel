// Toolchain.swift
// BuildSystemCore
//
// Locating build tools on the machine, and reading the version they report.
//
// A ToolDescriptor is part of a build's identity — it keys the cache — so the version
// recorded against a tool has to describe the binary that will actually run.  Hard-coding
// either the path or the version means the build system only works on one machine, and
// that cached outputs survive a toolchain upgrade they should have been invalidated by.

import Foundation

enum Toolchain {

    /// Absolute path to `toolName` in the active toolchain, via `xcrun --find`,
    /// or `nil` if there is no such tool.
    static func find(_ toolName: String) -> String? {
        guard let output = run("/usr/bin/xcrun", ["--find", toolName]) else { return nil }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    /// The canonical version string the tool at `path` reports, e.g.
    /// `Apple clang version 21.0.0`, or `nil` if it reports nothing recognisable.
    static func version(ofToolAt path: String) -> String? {
        guard let output = run(path, ["--version"]) else { return nil }
        return parseVersion(from: output)
    }

    /// Reduces any tool version output — or an already-recorded descriptor version — to
    /// the canonical `Apple <product> version <number>` form, so the two can be compared.
    ///
    /// Handles clang, which leads with the string, and swiftc, which reports its driver
    /// version first and carries a trailing build identifier.
    static func parseVersion(from output: String) -> String? {
        let pattern = #"Apple [A-Za-z]+ version [0-9]+(\.[0-9]+)*"#
        guard let range = output.range(of: pattern, options: .regularExpression) else { return nil }
        return String(output[range])
    }

    // MARK: - Process

    private static func run(_ launchPath: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
