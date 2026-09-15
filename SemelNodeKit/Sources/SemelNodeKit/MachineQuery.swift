//
//  MachineQuery.swift
//  SemelNodeKit
//
//  Asking the machine a question at launch: where a tool is, what version it reports,
//  which SDK is installed. The answers describe the host, not a node's inputs, and they
//  are the one process launch besides the sandboxed tool runner that the design accepts —
//  `HermeticityTests` holds every other file to that. A toolchain package puts its own
//  questions through here (`xcrun --find`, `<tool> --version`) rather than launching a
//  process of its own.
//

import Foundation

public enum MachineQuery {

    /// Runs the executable at `launchPath` with `arguments` and returns its trimmed
    /// standard output, or nil if there is no such executable, it exits non-zero or it
    /// prints nothing. Standard error is discarded: a question the machine cannot answer
    /// has no answer, and the caller decides what that means.
    ///
    /// What this inherits from the environment — `DEVELOPER_DIR`, `SDKROOT` — is how the
    /// machine's toolchain is selected, and it is why the SDK it yields is not a graph
    /// input (B-47).
    public static func output(of launchPath: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else {
            return nil
        }

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

        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        return text
    }

    /// The host as a tool descriptor names it: `macOS` for Darwin, otherwise the kernel's
    /// own name.
    public static var hostPlatform: String {
        let sysname = uname().sysname
        return sysname == "Darwin" ? "macOS" : sysname
    }

    /// The host's processor architecture as the kernel reports it: `arm64`, `x86_64`.
    public static var hostArchitecture: String {
        uname().machine
    }

    private static func uname() -> (sysname: String, machine: String) {
        var info = utsname()
        Foundation.uname(&info)
        return (string(from: &info.sysname), string(from: &info.machine))
    }

    private static func string<T>(from field: inout T) -> String {
        withUnsafePointer(to: &field) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
        }
    }
}
