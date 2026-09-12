// SwiftToolSupport.swift
// semel
//
// Shared helpers for Swift-based tool nodes (SwiftCompilerTool, SwiftLinkerTool).

import Foundation
import SemelNodeKit

// Every xcrun query goes through the toolchain helper — the one sanctioned process launch
// besides the sandboxed tool runner, and the one HermeticityTests allows.
private func xcrun(_ arguments: [String]) -> String? {
    AppleClangSwiftToolchainHelper.xcrun(arguments)
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
/// identical. Mirrors what ToolRunnerRegistry already does for a pinned tool version.
// Shared by the compiler and the linker, so this cannot name either one's namespace —
// the setting reaching this function is `swift.compiler.sdkVersion` for one caller and
// `swift.linker.sdkVersion` for the other.
func verifySDKVersion(_ declared: String?) throws {
    guard let declared else {
        return // nothing declared: the machine's SDK, as before
    }

    guard let actual = resolveSDKVersion() else {
        throw NodeError.other(message: "sdkVersion is declared as \(declared) "
                                     + "but no macOS SDK could be found on this machine")
    }
    guard actual == declared else {
        throw NodeError.other(message: "sdkVersion is declared as \(declared) "
                                     + "but this machine has \(actual). Install that SDK, or "
                                     + "change the setting — building against a different one "
                                     + "would produce artifacts that do not match what was declared.")
    }
}

/// The `swiftc` flag for a declared `optimisationLevel`, or nil when nothing is declared.
///
/// Named for what the user wants rather than for the flag: `-Osize` and `-O` are not a
/// scale, and a config that spelled the flags directly would invite `-Ounchecked`, which
/// removes bounds and overflow checks and is not something to reach by typo.
///
/// Nothing declared emits no flag at all, which is what keeps every existing tree building
/// exactly the arguments it built before this setting existed.
func swiftOptimisationFlag(_ declared: String?) throws -> String? {
    guard let declared else {
        return nil
    }
    switch declared {
    case "none":  return "-Onone"
    case "speed": return "-O"
    case "size":  return "-Osize"
    default:
        throw NodeError.other(message: "semel.config declares swift.compiler.optimisationLevel="
                                     + "\(declared), which is not one of none, speed or size.")
    }
}
