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
public class LocalFileSystemTool: ToolRunner {
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
                        expectedOutputFolders: [String],
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

        // The tool's stdout and stderr go to files in the sandbox, not pipes. Pipes need a
        // reader per stream draining while the tool runs, and an EOF that only arrives
        // once every copy of the write end is closed — the parent's, which Foundation is
        // expected to close on launch, and any a concurrently spawned sibling inherited.
        // Tools launch from many threads at once (phase 1 runs every ready node
        // concurrently), and the first IceCubes build — 86 ready nodes, eleven tools at
        // once — hung with every tool exited, dozens of pipe descriptors still open in the
        // parent, and every thread waiting in readDataToEndOfFile. A file has no such
        // lifetime: the tool writes it, exits, and it is read whole. The sandbox is the
        // tool's working directory and is deleted afterwards, so nothing leaks.
        let stdoutURL = Foundation.URL(fileURLWithPath: sandboxPath).appendingPathComponent(".semel-stdout")
        let stderrURL = Foundation.URL(fileURLWithPath: sandboxPath).appendingPathComponent(".semel-stderr")
        guard fileManager.createFile(atPath: stdoutURL.path, contents: nil),
              fileManager.createFile(atPath: stderrURL.path, contents: nil),
              let stdoutHandle = Foundation.FileHandle(forWritingAtPath: stdoutURL.path),
              let stderrHandle = Foundation.FileHandle(forWritingAtPath: stderrURL.path) else {
            throw SandboxCreationError(underlying: LocalFileSystemToolError.failedToWriteInputFile(
                fileName: stdoutURL.lastPathComponent,
                underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))))
        }
        process.standardOutput = stdoutHandle
        process.standardError  = stderrHandle

        do { try process.run() } catch {
            throw LocalFileSystemToolError.processLaunchFailed(underlying: error)
        }

        process.waitUntilExit()
        try? stdoutHandle.close()
        try? stderrHandle.close()

        let stdoutData = fileManager.contents(atPath: stdoutURL.path) ?? Foundation.Data()
        let stderrData = fileManager.contents(atPath: stderrURL.path) ?? Foundation.Data()

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

        // 7. Read back every file of each expected output folder. Sorted, so the tree a
        // node builds from them is the same value however the file system enumerates.
        for folder in expectedOutputFolders {
            let folderURL = Foundation.URL(fileURLWithPath: sandboxPath).appendingPathComponent(folder)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  let enumerator = fileManager.enumerator(at: folderURL, includingPropertiesForKeys: [.isRegularFileKey]) else {
                output.logError("Expected output folder not found: \(folder)")
                continue
            }
            let fileURLs = (enumerator.allObjects as? [Foundation.URL] ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .sorted { $0.path < $1.path }
            let prefix = folderURL.standardizedFileURL.path + "/"
            for fileURL in fileURLs {
                guard let data = fileManager.contents(atPath: fileURL.path) else {
                    output.logError("Expected output file could not be read: \(fileURL.path)")
                    continue
                }
                let relativePath = String(fileURL.standardizedFileURL.path.dropFirst(prefix.count))
                let permissions  = (try? fileManager.attributesOfItem(atPath: fileURL.path))?[.posixPermissions] as? NSNumber
                let mode         = permissions.map { UInt16(truncatingIfNeeded: $0.intValue) } ?? FileMetadata.defaultMode
                output.writeTreeEntry(folder, relativePath, [UInt8](data), mode)
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
