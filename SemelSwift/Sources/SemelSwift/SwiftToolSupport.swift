// SwiftToolSupport.swift
// build_system
//
// Shared helpers for Swift-based tool nodes (SwiftCompilerTool, SwiftLinkerTool).

import Foundation
import SemelNodeKit

/// Runs `xcrun` with `arguments` and returns its trimmed stdout, or nil if it is
/// unavailable or exits non-zero.
private func xcrun(_ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = arguments
    let stdoutPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = Pipe()   // suppress any xcrun warnings from leaking into our output
    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let raw = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: raw, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    } catch {
        return nil
    }
}

// Resolved once per process rather than once per node: every Swift compile and link
// asked xcrun the same question, which on a few-hundred-node build is a few hundred
// subprocesses for an answer that cannot change mid-build.
private let cachedSDKPath: String? = xcrun(["--show-sdk-path", "--sdk", "macosx"])


/// The current macOS SDK path.
///
/// Passing `-sdk <path>` to `swiftc` (both for compilation and linking) is required
/// when invoking it directly outside of `xcodebuild`, so it can locate:
///   - the Swift standard library modules (compiler)
///   - `libSystem` and other system libraries (linker)
///
/// Returns `nil` if `xcrun` is unavailable or returns a non-zero exit code.
func resolveSDKPath() -> String? {
    cachedSDKPath
}

private let cachedSDKVersion: String? = xcrun(["--show-sdk-version", "--sdk", "macosx"])

/// The macOS SDK version this machine reports, e.g. "26.5".
///
/// Compared against a declared `sdkVersion` rather than fed into a cache key. A key can
/// only stop a wrong reuse; it cannot cause a rebuild, because an unscheduled node never
/// recomputes it. Declaring the version makes it an ordinary graph input *and* gives this
/// something to check against.
func resolveSDKVersion() -> String? {
    cachedSDKVersion
}

/// Fails when the machine's SDK is not the one the build declared.
///
/// Deliberately loud rather than accommodating: silently compiling against a different SDK
/// than the one recorded is how two machines produce different artifacts that look
/// identical. Mirrors what ToolExecutorRegistry already does for a pinned tool version.
func verifySDKVersion(_ declared: String?) throws {
    guard let declared else { return }   // nothing declared: the machine's SDK, as before
    guard let actual = resolveSDKVersion() else {
        throw NodeError.other(message: "semel.config declares swift.sdkVersion=\(declared) "
                                     + "but no macOS SDK could be found on this machine")
    }
    guard actual == declared else {
        throw NodeError.other(message: "semel.config declares swift.sdkVersion=\(declared) "
                                     + "but this machine has \(actual). Install that SDK, or "
                                     + "change the setting — building against a different one "
                                     + "would produce artifacts that do not match what was declared.")
    }
}
