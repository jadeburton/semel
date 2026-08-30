//
//  LocalFileSystemTool.swift
//  SemelNodeKit
//

import Foundation
import SemelDatabaseModels

/// Runs a tool that lives in the local filesystem (e.g. /usr/bin/clang) inside a
/// temporary sandbox directory so that the tool cannot accidentally read files
/// that were not explicitly passed in as inputs.
///
/// Input files are populated via `DataObjectStore.project(hash:to:)`, which uses
/// an APFS copy-on-write clone (essentially free) when available.
/// All input bytes must already be stored in `DataObjectStore` before calling
/// `execute` — `FileNameAndContent` carries only the path and the hash.
public class LocalFileSystemTool: ToolExecutor {
    private let localPath: String

    public init(localPath: String) throws {
        self.localPath = localPath

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: localPath, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw LocalFileSystemToolError.toolNotFound(path: localPath)
        }
        guard fileManager.isExecutableFile(atPath: localPath) else {
            throw LocalFileSystemToolError.toolNotExecutable(path: localPath)
        }
    }

    public func execute(arguments: [String],
                        environment: [String: String],
                        inputFiles: [FileNameAndContent],
                        expectedOutputFileNames: [String],
                        output: ToolOutput) throws -> ToolExecuteResult {

        let fileManager = FileManager.default

        // 1. Create a temporary sandbox directory.
        let sandboxPath: String
        let canonicalSandboxPath: String
        do {
            let sandboxURL = try fileManager.url(for: .itemReplacementDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: fileManager.temporaryDirectory,
                                                 create: true)
            sandboxPath = sandboxURL.path
            // On macOS, /var is a symlink to /private/var. Tools like SPM call
            // realpath() internally and write /private/var/... in their output
            // even when the process ran in /var/.... Normalise the path here so
            // callers can match against those output paths.
            canonicalSandboxPath = sandboxPath.hasPrefix("/var/") ? "/private" + sandboxPath : sandboxPath
        } catch {
            throw SandboxCreationError(underlying: error)
        }

        defer { try? fileManager.removeItem(atPath: sandboxPath) }

        // 2. Populate input files in the sandbox via DataObjectStore (APFS clone).
        for inputFile in inputFiles {

            let destinationURL = Foundation.URL(fileURLWithPath: sandboxPath).appendingPathComponent(inputFile.filePath)
            let containingDirectory = destinationURL.deletingLastPathComponent().path

            do {
                if !fileManager.fileExists(atPath: containingDirectory) {
                    try fileManager.createDirectory(atPath: containingDirectory,
                                                    withIntermediateDirectories: true)
                }

                // Throws if not found.
                try DataObjectStore.shared.project(hash: inputFile.hash, to: destinationURL)

            } catch {
                throw LocalFileSystemToolError.failedToWriteInputFile(fileName: inputFile.filePath,
                                                               underlying: error)
            }
        }

        // 3. Configure and launch the process.
        let process = Foundation.Process()
        process.executableURL = Foundation.URL(fileURLWithPath: localPath)
        process.arguments = arguments
        process.currentDirectoryURL = Foundation.URL(fileURLWithPath: sandboxPath)

        var processEnvironment: [String: String] = [
            "PATH":   "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME":   sandboxPath,
            "TMPDIR": sandboxPath,
        ]

        for (key, value) in environment {
            processEnvironment[key] = value
        }

        process.environment = processEnvironment

        let stdoutPipe = Foundation.Pipe()
        let stderrPipe = Foundation.Pipe()
        process.standardOutput = stdoutPipe
        process.standardError  = stderrPipe

        do { try process.run() } catch {
            throw LocalFileSystemToolError.processLaunchFailed(underlying: error)
        }

        // 4. Drain stdout and stderr on background threads WHILE the process runs.
        //    Reading after waitUntilExit() risks deadlock if the tool writes more
        //    than the OS pipe buffer (~64 KB) before the process exits.
        var stdoutData = Foundation.Data()
        var stderrData = Foundation.Data()
        let ioGroup = DispatchGroup()

        ioGroup.enter()

        DispatchQueue.global(qos: .utility).async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            ioGroup.leave()
        }

        ioGroup.enter()

        DispatchQueue.global(qos: .utility).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            ioGroup.leave()
        }

        process.waitUntilExit()
        ioGroup.wait()

        let exitCode = process.terminationStatus

        // 5. Forward stdout and stderr to ToolOutput.
        if let text = String(data: stdoutData, encoding: .utf8), !text.isEmpty {
            output.logMessage(text)
        }

        if let text = String(data: stderrData, encoding: .utf8), !text.isEmpty {
            output.logError(text)
        }

        // 6. Read back expected output files and forward via ToolOutput.
        for expectedOutputFileName in expectedOutputFileNames {
            let outputFileURL = Foundation.URL(fileURLWithPath: sandboxPath)
                .appendingPathComponent(expectedOutputFileName)
            if let data = fileManager.contents(atPath: outputFileURL.path) {
                output.write(expectedOutputFileName, [UInt8](data))
            } else {
                output.logError("Expected output file not found: \(expectedOutputFileName)")
            }
        }

        return .init(exitCode: exitCode, sandboxPathUsed: canonicalSandboxPath)
    }
}

public enum LocalFileSystemToolError: Error {
    case toolNotFound(path: String)
    case toolNotExecutable(path: String)
    case failedToWriteInputFile(fileName: String, underlying: Error)
    case failedToReadOutputFile(fileName: String)
    case processLaunchFailed(underlying: Error)
}

/// The temporary sandbox could not be created.
///
/// Its own type rather than a case of `LocalFileSystemToolError`, because conformance to
/// `UnrecoverableError` is per type and the other cases are ordinary node failures — a tool
/// that is missing, a tool that produced no output. Another node using another tool can still
/// build after those. Not after this one: every tool runs inside a sandbox, so if one cannot
/// be created there is nowhere left to work and the next node hits the same wall.
///
/// Stopping is right even once tool execution moves out to a separate runner process, on
/// another machine or in a container. There the runner dies and recovery becomes the server's
/// job — switch to another runner, or wait for this one to cycle and reconnect — which is a
/// decision that belongs a level up, not inside the thing that has run out of room.
public struct SandboxCreationError: UnrecoverableError {
    public let underlying: Error

    public init(underlying: Error) {
        self.underlying = underlying
    }

    public var unrecoverableDescription: String {
        """
        Could not create a temporary directory to run tools in.

        \(underlying.localizedDescription)

        Every tool runs inside one, so nothing can be built until this is fixed. Check free
        space and permissions on the volume holding TMPDIR.
        """
    }
}
