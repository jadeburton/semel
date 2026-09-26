//
//  MachineFacts.swift
//  SemelEndToEndTests
//
//  Two facts about the machine the tests run on, read the way `semel tools` reads them,
//  so a test can check the machine file the harness had written against the machine.
//

import Foundation
import SemelTestSupport

enum MachineFacts {

    /// The first line of `xcrun clang --version`, the `Apple clang version …` string the
    /// tool descriptor carries.
    static func clangVersion() throws -> String {
        try firstLine(of: "/usr/bin/xcrun", arguments: ["clang", "--version"], step: "configure: clang --version")
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
