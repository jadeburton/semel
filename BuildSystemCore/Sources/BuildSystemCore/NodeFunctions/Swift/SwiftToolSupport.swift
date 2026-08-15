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

private let cachedSDKIdentity: String? = {
    guard let version = xcrun(["--show-sdk-version", "--sdk", "macosx"]) else { return nil }
    guard let build = xcrun(["--show-sdk-build-version", "--sdk", "macosx"]) else { return version }
    return "\(version) (\(build))"
}()

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

/// The SDK's version and build, for the cache key — deliberately *not* its path.
///
/// The SDK changes what a compile produces, so it has to contribute to the key or two
/// different builds collide on one entry. But the path must not: this machine reports
/// SDK 26.5 from inside `Xcode_26_6.app`, and two developers with the same SDK installed
/// at different paths would otherwise miss each other's cache entries for no reason.
/// Keying on the version is the same choice `DefaultTools` makes for tools themselves —
/// take it from the machine, and record what was taken.
///
/// Returns `nil` when the SDK cannot be resolved, in which case no `-sdk` is passed
/// either, so there is nothing to record.
func resolveSDKIdentity() -> String? {
    cachedSDKIdentity
}
