//
//  AppInspection.swift
//  SemelEndToEndTests
//
//  What an exported Mac app's executable says about itself, asked with the tools a
//  developer would ask with. For an app the roster does not run — NetNewsWire's wants
//  its accounts and a window server — this is what it can check beyond a list of files.
//

import Foundation

enum AppInspection {

    /// That `executable` is an arm64 Mach-O executable, loads a framework by its
    /// `installName` and finds it through a Mac bundle's runpath,
    /// `@executable_path/../Frameworks`: what embedding a binary target's framework means
    /// (B-77).
    static func checkLoadsEmbeddedFramework(executable: URL, installName: String) throws {
        let kind = try run(["/usr/bin/file", "-b", executable.path], viaXcrun: false)
        guard kind.contains("Mach-O 64-bit executable arm64") else {
            throw EndToEndFailure(step: "file", message: "\(executable.lastPathComponent) is not an arm64 executable: \(kind)")
        }
        let libraries = try run(["otool", "-L", executable.path])
        guard libraries.contains(installName) else {
            throw EndToEndFailure(step: "otool -L", message: "\(executable.lastPathComponent) does not load \(installName):\n\(libraries)")
        }
        let loadCommands = try run(["otool", "-l", executable.path])
        guard loadCommands.contains("path @executable_path/../Frameworks") else {
            throw EndToEndFailure(step: "otool -l", message: "no LC_RPATH @executable_path/../Frameworks:\n\(loadCommands)")
        }
    }

    /// Runs a tool through `xcrun`, or by its path, to completion, returning what it
    /// printed; a non-zero status is a failure naming the command.
    @discardableResult
    static func run(_ arguments: [String], viaXcrun: Bool = true) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: viaXcrun ? "/usr/bin/xcrun" : arguments[0])
        process.arguments = viaXcrun ? arguments : Array(arguments.dropFirst())
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw EndToEndFailure(step: "inspect the app",
                                  message: "\(arguments.joined(separator: " ")) exited \(process.terminationStatus):\n\(text)")
        }
        return text
    }
}
