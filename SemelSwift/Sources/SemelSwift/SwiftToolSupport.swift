// SwiftToolSupport.swift
// semel
//
// Shared helpers for Swift-based tool nodes (SwiftCompiler, SwiftLinker).

import Foundation
import SemelNodeKit

/// Runs `xcrun` with `arguments` and returns its trimmed output, or nil if it has none.
/// Every question this package asks the machine — where a tool is, which SDK is installed
/// — goes through `MachineQuery`, the one launch-time process runner HermeticityTests
/// allows besides the sandboxed tool runner.
func xcrun(_ arguments: [String]) -> String? {
    MachineQuery.output(of: "/usr/bin/xcrun", arguments)
}

// MARK: - Which SDK

/// The SDK the Swift tools use when a configuration names none: the machine's macOS SDK,
/// which is all they ever built against before `sdk` became a setting. An iOS package
/// declares `swift.compiler.sdk=iphonesimulator` (a name as `xcrun --sdk` knows it) and a
/// `target` triple beside it.
let defaultSDKName = "macosx"

/// What xcrun knows about one SDK, asked once per process per name: every Swift compile
/// and link asks the same questions, which on a few-hundred-node build is a few hundred
/// subprocesses for answers that cannot change mid-build. Nodes process concurrently in
/// phase 1, so the memo is locked.
private final class SDKQueries {
    static let shared = SDKQueries()

    private let lock = NSLock()
    private var paths: [String: String?] = [:]
    private var identities: [String: String?] = [:]

    func path(sdk: String) -> String? {
        memoized(\.paths, sdk) { xcrun(["--show-sdk-path", "--sdk", sdk]) }
    }

    func identity(sdk: String) -> String? {
        memoized(\.identities, sdk) {
            guard let version = xcrun(["--show-sdk-version", "--sdk", sdk]),
                  let build   = xcrun(["--show-sdk-build-version", "--sdk", sdk]) else {
                return nil
            }
            return "\(version) (\(build))"
        }
    }

    /// Takes the table by key path rather than `inout`: an `inout` argument's access begins
    /// at the call, before the lock is taken, and writes back after it is released.
    private func memoized(_ table: ReferenceWritableKeyPath<SDKQueries, [String: String?]>, _ sdk: String,
                          _ query: () -> String?) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let known = self[keyPath: table][sdk] {
            return known
        }
        let answer = query()
        self[keyPath: table][sdk] = answer
        return answer
    }
}

/// The path of the named SDK, or nil if xcrun knows no such SDK.
///
/// Passing `-sdk <path>` to `swiftc` (both for compilation and linking) is required
/// when invoking it directly outside of `xcodebuild`, so it can locate:
///   - the Swift standard library modules (compiler)
///   - `libSystem` and other system libraries (linker)
func resolveSDKPath(sdk: String = defaultSDKName) -> String? {
    SDKQueries.shared.path(sdk: sdk)
}

/// The named SDK this machine has, as version and build: "26.5 (25F70)".
///
/// The build number is part of the identity. Apple ships more than one build of an SDK
/// version, and two of them can differ in headers and stubs; a check on "26.5" alone would
/// pass on both machines and let them compile against different SDKs while agreeing that
/// they had not. (B-47's narrow half. The wide half — the SDK's contents are still not a
/// graph input — is B-03's.)
///
/// Compared against a declared `sdkVersion` rather than fed into a cache key. A key can
/// only stop a wrong reuse; it cannot cause a rebuild, because an unscheduled node never
/// recomputes it. Declaring the version makes it an ordinary graph input *and* gives this
/// something to check against.
func resolveSDKVersion(sdk: String = defaultSDKName) -> String? {
    SDKQueries.shared.identity(sdk: sdk)
}

/// Fails when the machine's copy of the declared SDK is not the one the build declared.
///
/// Deliberately loud rather than accommodating: silently compiling against a different SDK
/// than the one recorded is how two machines produce different artifacts that look
/// identical. Mirrors what ToolRunnerRegistry already does for a pinned tool version.
// Shared by the compiler and the linker, so this cannot name either one's namespace —
// the setting reaching this function is `swift.compiler.sdkVersion` for one caller and
// `swift.linker.sdkVersion` for the other.
func verifySDKVersion(_ declared: String?, sdk: String = defaultSDKName) throws {
    guard let declared else {
        return // nothing declared: the machine's SDK, as before
    }

    guard let actual = resolveSDKVersion(sdk: sdk) else {
        throw NodeError.other(message: "sdkVersion is declared as \(declared) "
                                     + "but no SDK named \(sdk) could be found on this machine")
    }
    guard actual == declared else {
        // A bare version is the pre-build-number form. It is not a partial match — the
        // gap it leaves is the one this check exists to close — but the fix is a paste.
        if !declared.contains("(") {
            throw NodeError.other(message: "sdkVersion is declared as \(declared), but the "
                                         + "SDK build number is part of the identity: this "
                                         + "machine has \(actual). Declare that instead.")
        }
        throw NodeError.other(message: "sdkVersion is declared as \(declared) "
                                     + "but this machine has \(actual). Install that SDK, or "
                                     + "change the setting — building against a different one "
                                     + "would produce artifacts that do not match what was declared.")
    }
}

/// The `-swift-version` value for a declared `languageMode`, or nil when nothing is declared.
///
/// The converter derives it from a target's `.swiftLanguageMode`; it is the mode's version
/// string as `swiftc` spells it. Nothing declared emits no flag, which keeps every target
/// without one building exactly the arguments it built before this setting existed.
func swiftLanguageModeVersion(_ declared: String?) throws -> String? {
    guard let declared else {
        return nil
    }
    let accepted = ["4", "4.2", "5", "6"]
    guard accepted.contains(declared) else {
        throw NodeError.other(message: "languageMode=\(declared) is not a Swift language mode; "
                                     + "swiftc accepts \(accepted.joined(separator: ", ")).")
    }
    return declared
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
