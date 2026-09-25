//
//  Perturbation.swift
//  SemelEndToEndTests
//
//  What a build is told about its surroundings that no cache key names, varied on
//  purpose so that a build which reads any of it is caught by the diff.
//

import Foundation
import SemelTestSupport

/// A set of environment variables and a working directory handed to one cold build, so
/// its export tree can be compared with a build that ran without them. None of it is in
/// a cache key, and none of it may reach an output: a difference means a key or a
/// sandbox that is under-specified.
///
/// What is varied is what a build can be given without privileges and a node or a tool
/// plausibly reads: `TMPDIR`, the scratch directory anything that asks the environment
/// for one writes into, the working directory both processes start in, the locale the
/// toolchain formats and collates with, and the time zone it renders a date in. A host
/// name cannot be changed without privileges, so it is left alone; the wall clock cannot
/// be moved without privileges either, and the builds in the separate homes already run
/// at different seconds, which is the same evidence.
///
/// `TMPDIR` does not move the tool sandboxes themselves: on macOS `FileManager`'s
/// temporary directory comes from `confstr(_CS_DARWIN_USER_TEMP_DIR)` and ignores the
/// variable, and `LocalFileSystemTool` hands each tool the sandbox as its own `TMPDIR`
/// anyway. The sandbox path differs between any two builds regardless, which is what the
/// two homes and the second mount already prove; what this variable adds is every node
/// and every process the engine runs outside a sandbox — tool discovery and the `xcrun`
/// it goes through leave their scratch directories in whatever `TMPDIR` names.
struct Perturbation {

    /// Merged over the server's own variables, for both `semelserv` and `semel`.
    let variables: [String: String]
    /// The working directory both processes are started in.
    let workingDirectory: URL
    /// The perturbation named in a failure message.
    let description: String

    /// `TMPDIR` and the working directory are fresh directories under `root`, so
    /// anything the build derives from either points somewhere the first build never saw.
    static func under(root: URL) throws -> Perturbation {
        let temporary = root.appendingPathComponent("perturbed-tmp", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("perturbed-cwd-with-a-longer-name", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let locale = installedLocale
        let timeZone = "Pacific/Kiritimati"
        return Perturbation(
            variables: ["TMPDIR": temporary.path, "LANG": locale, "LC_ALL": locale, "TZ": timeZone],
            workingDirectory: workingDirectory,
            description: "TMPDIR=\(temporary.path), LANG=LC_ALL=\(locale), TZ=\(timeZone), "
                       + "working directory \(workingDirectory.path)")
    }

    /// `de_DE.UTF-8` where the machine has it: a UTF-8 locale that differs from the usual
    /// `en_US.UTF-8` in how it collates and how it formats a number. `C.UTF-8`, which
    /// every machine has, where it does not — a weaker perturbation, but never a missing
    /// locale, which a tool may reject outright.
    static let installedLocale: String = {
        let fallback = "C.UTF-8"
        let preferred = "de_DE.UTF-8"
        let process = ManagedProcess(executable: URL(fileURLWithPath: "/usr/bin/locale"),
                                     arguments: ["-a"], environment: [:])
        do {
            try process.start()
        } catch {
            return fallback
        }
        guard process.waitForExit(timeout: 10) == 0 else {
            return fallback
        }
        let installed = process.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return installed.contains(preferred) ? preferred : fallback
    }()
}
