// SettingArgument.swift
// SemelNodeKit
//
// The link between a setting in a config file and the command-line argument a node built
// from it.
//
// A tool that rejects an argument names the argument and nothing else: clang says
// `unknown target triple 'x86_64-apple-nowhere'` and leaves the reader to work out that
// the triple was `clang.preprocessor.target` in a semel.config. A node that hands its
// settings to `failureMessage` closes that gap — the message gains one sentence per
// setting the tool complained about, naming the key, its value and where the values this
// toolchain accepts are listed.
//
// Which config file the value came from is deliberately not part of the sentence: the
// merge that produces a node's configuration does not carry a value's origin, and the key
// is enough to find the line.

/// One command-line argument a node built from a setting, and how a tool complains about it.
///
/// Constructed through the factories below rather than field by field: what a flag is
/// called, which phrases it draws out of the tool and where its accepted values are listed
/// are three halves of one fact, and stating them apart is how they drift.
public struct SettingArgument {

    /// The setting's key, fully qualified: `clang.preprocessor.target`.
    public let key: String

    /// What the setting says, spelled as the config file spells it.
    public let value: String

    /// The flag the value became on the command line.
    public let flag: String

    /// The text a tool echoes back when it rejects the argument, or nil when the
    /// argument's own text is no evidence — an SDK path is quoted by every diagnostic
    /// whose note sits in an SDK header, so matching on it would blame the SDK setting for
    /// a wrong argument type.
    let echoedText: String?

    /// Lowercased fragments of the complaints this flag draws. Short, and each specific
    /// enough that no other argument produces it.
    let phrases: [String]

    /// Where the reader finds the values the installed toolchain accepts, as the clause
    /// that completes the sentence.
    let advice: String

    /// True when `output` is complaining about this argument: it echoes the text that
    /// reached the command line, or it carries one of the phrases the flag draws.
    func isMentioned(in output: String) -> Bool {
        let lowered = output.lowercased()
        if let echoedText, !echoedText.isEmpty, lowered.contains(echoedText.lowercased()) {
            return true
        }
        return phrases.contains { lowered.contains($0) }
    }

    /// The one sentence a matched setting adds to a failure message.
    var sentence: String {
        "`\(key)` is `\(value)`; \(advice)"
    }

    /// A sentence for each setting `output` complains about, in the order the node built
    /// the arguments. Empty when the tool's complaint is about none of them, which is the
    /// ordinary case: a compile error is about the source file, not the command line.
    public static func sentences(for settings: [SettingArgument], matching output: String) -> [String] {
        settings.filter { $0.isMentioned(in: output) }.map(\.sentence)
    }
}

// MARK: - The flags a new user gets wrong

public extension SettingArgument {

    /// clang's `-target`. It echoes the triple whichever way it rejects it:
    /// `error: unknown target triple 'nonsense-triple'` for a triple it cannot parse, and
    /// `error: unable to create target: 'No available targets are compatible with triple
    /// "sparc-apple-macos14.0"'` for one it parses and has no backend for.
    static func clangTarget(key: String, value: String) -> SettingArgument {
        .init(key: key,
              value: value,
              flag: "-target",
              echoedText: value,
              phrases: ["unknown target triple",
                        "no available targets are compatible",
                        "unable to create target"],
              advice: "`clang -print-targets` lists the architectures this toolchain builds "
                    + "for, which is a triple's first word.")
    }

    /// The SDK path a compile or preprocess turns into `-isysroot`. clang mentions it once,
    /// as `clang: warning: no such sysroot directory: '/no/such/sdk' [-Wmissing-sysroot]`,
    /// and then fails over the headers it could not find; the warning is the only line that
    /// is about the setting.
    static func clangSysroot(key: String, value: String) -> SettingArgument {
        .init(key: key,
              value: value,
              flag: "-isysroot",
              echoedText: nil,
              phrases: ["no such sysroot directory"],
              advice: "`xcrun --show-sdk-path` prints the path of an SDK installed here.")
    }

    /// The SDK path a link turns into `-L <sdkPath>/usr/lib`. The linker echoes the search
    /// path — `ld: warning: search path '/no/such/sdk/usr/lib' not found` — and, unlike a
    /// sysroot, the path appears in no other diagnostic, because a linker cites libraries
    /// rather than headers. Its own failure is `ld: library 'System' not found`.
    static func clangLibrarySearchPath(key: String, value: String, searchPath: String) -> SettingArgument {
        .init(key: key,
              value: value,
              flag: "-L",
              echoedText: searchPath,
              phrases: ["library 'system' not found"],
              advice: "`xcrun --show-sdk-path` prints the path of an SDK installed here.")
    }

    /// swiftc's `-target`. `error: unknown target 'nonsense'` for a triple it cannot parse;
    /// a parsed triple with no frontend fails one step further out, as `error: frontend job
    /// retrieving target info failed with code 1: <unknown>:0: error: unsupported target
    /// architecture: 'sparc'`.
    static func swiftTarget(key: String, value: String) -> SettingArgument {
        .init(key: key,
              value: value,
              flag: "-target",
              echoedText: value,
              phrases: ["unknown target", "unsupported target architecture"],
              advice: "`swiftc -print-target-info` prints the triple this toolchain builds "
                    + "for by default.")
    }

    /// swiftc's `-sdk`, whose value is an SDK name (`macosx`) that `xcrun` resolves to a
    /// path before it reaches the command line, so the tool complains about a path the
    /// setting never spells — hence phrases alone. One bad path draws all three of
    /// `warning: no such SDK: /no/such/sdk`, `<unknown>:0: warning: no such sysroot
    /// directory: '/no/such/sdk'` and `<unknown>:0: error: unable to load standard library
    /// for target 'arm64-apple-macosx26.0'`.
    static func swiftSDK(key: String, value: String) -> SettingArgument {
        .init(key: key,
              value: value,
              flag: "-sdk",
              echoedText: nil,
              phrases: ["no such sdk",
                        "no such sysroot directory",
                        "unable to load standard library"],
              advice: "`xcodebuild -showsdks` lists the SDKs installed here, as `-sdk <name>` "
                    + "names them.")
    }
}
