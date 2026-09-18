//
//  ClangConfigTemplate.swift
//  SemelEndToEndTests
//
//  The C fixtures' base config carries two facts about the machine: the clang version
//  string the toolchain checks against, and the macOS SDK path. Rendered at run time,
//  the way `prepare` derives the same facts for a Swift tree.
//

import Foundation
import SemelTestSupport

enum ClangConfigTemplate {

    static func render(template: URL, to destination: URL) throws {
        var text = try String(contentsOf: template, encoding: .utf8)
        text = text.replacingOccurrences(of: "${CLANG_VERSION}", with: try clangVersion())
        text = text.replacingOccurrences(of: "${MACOS_SDK_PATH}", with: try macOSSDKPath())
        guard !text.contains("${") else {
            throw EndToEndFailure(step: "configure", message: "unrendered placeholder left in \(destination.lastPathComponent)")
        }
        try text.write(to: destination, atomically: true, encoding: .utf8)
    }

    /// The first line of `xcrun clang --version`, the `Apple clang version …` string the
    /// tool descriptor carries.
    static func clangVersion() throws -> String {
        let output = try firstLine(of: "/usr/bin/xcrun", arguments: ["clang", "--version"], step: "configure: clang --version")
        return output
    }

    static func macOSSDKPath() throws -> String {
        try firstLine(of: "/usr/bin/xcrun", arguments: ["--sdk", "macosx", "--show-sdk-path"], step: "configure: show-sdk-path")
    }

    private static func firstLine(of executable: String, arguments: [String], step: String) throws -> String {
        let process = ManagedProcess(executable: URL(fileURLWithPath: executable), arguments: arguments, environment: [:])
        try process.start()
        guard let status = process.waitForExit(timeout: 60), status == 0,
              let line = process.output.split(separator: "\n").first, !line.isEmpty else {
            if process.isRunning {
                process.kill()
                _ = process.waitForExit(timeout: 5)
            }
            throw EndToEndFailure(step: step, message: "no usable output", commandLine: process.commandLine,
                                  status: process.isRunning ? nil : process.terminationStatus, outputTail: process.outputTail())
        }
        return String(line)
    }
}
