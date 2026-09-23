// SettingArgument.swift
// SemelNodeKit
//
// The link between a setting in a config file and the command-line argument a node built
// from it.
//
// A tool that rejects an argument names the argument and nothing else: clang says
// `error: unknown target triple 'nonsense-triple'` and leaves the reader to work out that
// the triple was `clang.preprocessor.target` in a semel.config. A node that hands its
// settings to `failureMessage` closes that gap — the message gains one sentence per
// setting the tool complained about, naming the key, its value and where the values this
// toolchain accepts are listed.
//
// Which config file the value came from is deliberately not part of the sentence: the
// merge that produces a node's configuration does not carry a value's origin, and the key
// is enough to find the line.

import Foundation

/// One command-line argument a node built from a setting, and how a tool complains about it.
///
/// Constructed through the factories below rather than field by field: which phrases a flag
/// draws out of the tool and where its accepted values are listed are one fact about that
/// flag, and stating it at each call site is how the statements drift apart.
public struct SettingArgument {

    /// The setting's key, fully qualified: `clang.preprocessor.target`.
    public let key: String

    /// What the setting says, spelled as the config file spells it.
    public let value: String

    /// The text a tool echoes back when it rejects the argument, or nil when the
    /// argument's own text is no evidence. Nil for all but one flag, because a tool quotes
    /// an argument in diagnostics that are not about it: a compiler prints the target
    /// triple when the *SDK* it was given cannot serve it, and an SDK path whenever a note
    /// lands in a system header.
    let echoedText: String?

    /// Lowercased fragments of the complaints this flag draws. Short, and each specific
    /// enough that no other argument produces it.
    let phrases: [String]

    /// Where the reader finds the values the installed toolchain accepts, as the clause
    /// that completes the sentence.
    let advice: String

    /// True when `output` is complaining about this argument: it carries one of the
    /// phrases the flag draws, or echoes the text that reached the command line.
    ///
    /// The source a compiler quotes around an error is not read. A file containing one of
    /// these phrases — this package's own tests are such files — would otherwise be taken
    /// for the tool complaining about an argument.
    func isMentioned(in output: String) -> Bool {
        let diagnostics = Self.diagnostics(in: output).lowercased()
        if let echoedText, !echoedText.isEmpty, diagnostics.contains(echoedText.lowercased()) {
            return true
        }
        return phrases.contains { diagnostics.contains($0) }
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

    /// The tool's own words, without the source it quoted back.
    ///
    /// Only the quoted source is dropped, and not everything that lacks a severity: a
    /// linker's own failure carries none — `ld: library 'System' not found` — and it is
    /// the line that identifies the argument behind it.
    private static func diagnostics(in output: String) -> String {
        output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !isQuotedSource($0) }
            .joined(separator: "\n")
    }

    /// A line of the source the tool quoted: its line number, then a bar, then the text —
    /// or the bar alone, under which the carets and the fix-it go. The form clang and
    /// swiftc both print, and the only one in which a tool repeats text it did not write.
    private static func isQuotedSource(_ line: String) -> Bool {
        var rest = Substring(line)
        rest = rest.drop { $0.isNumber }
        rest = rest.drop { $0 == " " }
        return rest.first == "|"
    }
}

// MARK: - The flags a new user gets wrong

public extension SettingArgument {

    /// clang's `-target`. It says `error: unknown target triple 'nonsense-triple'` for a
    /// triple it cannot parse and `error: unable to create target: 'No available targets
    /// are compatible with triple "sparc-apple-macos14.0"'` for one it parses and has no
    /// backend for. The value is no evidence: clang rewrites a triple it could not read
    /// before quoting it, so `-target riscv64-apple-macos14.0` is reported as
    /// `unknown target triple 'unknown-apple-macosx14.0.0'`.
    static func clangTarget(key: String, value: String) -> SettingArgument {
        .init(key: key,
              value: value,
              echoedText: nil,
              phrases: ["unknown target triple",
                        "no available targets are compatible",
                        "unable to create target"],
              advice: "`clang -print-target-triple` prints the triple this toolchain builds "
                    + "for when none is given.")
    }

    /// The SDK path a compile or preprocess turns into `-isysroot`. clang mentions it once,
    /// as `clang: warning: no such sysroot directory: '/no/such/sdk' [-Wmissing-sysroot]`,
    /// and then fails over the headers it could not find; the warning is the only line that
    /// is about the setting.
    static func clangSysroot(key: String, value: String) -> SettingArgument {
        .init(key: key,
              value: value,
              echoedText: nil,
              phrases: ["no such sysroot directory"],
              advice: "`xcrun --sdk <name> --show-sdk-path` prints the path of an SDK "
                    + "installed here.")
    }

    /// The SDK path a link turns into `-L <sdkPath>/usr/lib`. The linker echoes the search
    /// path — `ld: warning: search path '/no/such/sdk/usr/lib' not found` — and that path
    /// is evidence where other arguments' values are not: a linker cites libraries rather
    /// than headers, so it appears in no diagnostic that is about something else. Its own
    /// failure is `ld: library 'System' not found`.
    static func clangLibrarySearchPath(key: String, value: String, searchPath: String) -> SettingArgument {
        .init(key: key,
              value: value,
              echoedText: searchPath,
              phrases: ["library 'system' not found"],
              advice: "`xcrun --sdk <name> --show-sdk-path` prints the path of an SDK "
                    + "installed here.")
    }

    /// swiftc's `-target`. `error: unknown target 'nonsense'` for a triple it cannot parse;
    /// a parsed triple with no frontend fails one step further out, as `error: frontend job
    /// retrieving target info failed with code 1: <unknown>:0: error: unsupported target
    /// architecture: 'sparc'`. The value is no evidence here either: swiftc quotes the
    /// triple verbatim when the SDK it was given cannot serve it, which is a complaint
    /// about the SDK.
    static func swiftTarget(key: String, value: String) -> SettingArgument {
        .init(key: key,
              value: value,
              echoedText: nil,
              phrases: ["unknown target", "unsupported target architecture"],
              advice: "`swiftc -print-target-info -target \(value)` says whether this "
                    + "toolchain builds for it.")
    }

    /// swiftc's `-sdk`, whose value is an SDK name (`macosx`) that `xcrun` resolves to a
    /// path before it reaches the command line, so the tool complains about a path the
    /// setting never spells — hence phrases alone. A path that is no SDK draws
    /// `warning: no such SDK: /no/such/sdk`, `<unknown>:0: warning: no such sysroot
    /// directory: '/no/such/sdk'` and `<unknown>:0: error: unable to load standard library
    /// for target 'arm64-apple-macos14.0'`; an SDK that cannot serve the target draws the
    /// last of those beside `<unknown>:0: warning: using sysroot for 'MacOSX' but targeting
    /// 'iPhone'`.
    static func swiftSDK(key: String, value: String) -> SettingArgument {
        .init(key: key,
              value: value,
              echoedText: nil,
              phrases: ["no such sdk",
                        "no such sysroot directory",
                        "unable to load standard library"],
              advice: "`xcrun --sdk \(value) --show-sdk-path` resolves the name this key takes.")
    }
}
