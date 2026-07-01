// SwiftToolSupport.swift
// build_system
//
// Shared helpers for Swift-based tool nodes (SwiftCompilerTool, SwiftLinkerTool).

import Foundation

/// Resolves the current macOS SDK path by running `xcrun --show-sdk-path --sdk macosx`.
///
/// Passing `-sdk <path>` to `swiftc` (both for compilation and linking) is required
/// when invoking it directly outside of `xcodebuild`, so it can locate:
///   - the Swift standard library modules (compiler)
///   - `libSystem` and other system libraries (linker)
///
/// Returns `nil` if `xcrun` is unavailable or returns a non-zero exit code.
func resolveSDKPath() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["--show-sdk-path", "--sdk", "macosx"]
    let stdoutPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = Pipe()   // suppress any xcrun warnings from leaking into our output
    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let raw = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: raw, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return (path?.isEmpty == false) ? path : nil
    } catch {
        return nil
    }
}
