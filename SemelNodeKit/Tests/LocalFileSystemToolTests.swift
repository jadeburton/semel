//
//  LocalFileSystemToolTests.swift
//  SemelNodeKit
//

@testable import SemelNodeKit
import Foundation
import XCTest

/// B-02. Hermeticity is load-bearing: a tool's output must be a function of its declared
/// inputs, so what the user's shell happens to export, and where the Semel process happens
/// to be running, must be invisible to it. These pin the two properties the sandboxed
/// runner already has, so a change that starts inheriting either fails here and not in a
/// cache that hits on one machine and misses on the next.
final class LocalFileSystemToolTests: XCTestCase {

    private func runShell(_ script: String) throws -> SimplifiedToolExecuteResult {
        try LocalFileSystemTool(localPath: "/bin/sh")
            .execute(arguments: ["-c", script],
                     environment: [:],
                     inputFiles: [],
                     expectedOutputFileNames: [])
    }

    func test_aToolDoesNotSeeTheParentProcessEnvironment() throws {
        setenv("SEMEL_TEST_LEAK", "leaked", 1)
        defer { unsetenv("SEMEL_TEST_LEAK") }

        let result = try runShell("echo \"marker=[$SEMEL_TEST_LEAK]\"")

        XCTAssertEqual(result.exitCode, 0, result.errorOutput)
        XCTAssertTrue(result.infoOutput.contains("marker=[]"),
                      "the parent's environment must not reach the tool, got: \(result.infoOutput)")
    }

    /// The variables a tool does get are the sandbox's, not the user's: HOME and TMPDIR
    /// both point inside the sandbox, so a tool that writes "somewhere in $HOME" still
    /// cannot escape it. PATH is fixed rather than inherited.
    func test_theEnvironmentAToolGetsIsTheSandboxes() throws {
        // `pwd -P` resolves /var to /private/var, which is how sandboxPathUsed is reported.
        let result = try runShell("""
            echo "home=$(cd "$HOME" && pwd -P)"; echo "tmp=$(cd "$TMPDIR" && pwd -P)"; echo "path=$PATH"
            """)

        XCTAssertEqual(result.exitCode, 0, result.errorOutput)
        XCTAssertTrue(result.infoOutput.contains("home=\(result.sandboxPathUsed)\n"),
                      "HOME must be the sandbox, got: \(result.infoOutput)")
        XCTAssertTrue(result.infoOutput.contains("tmp=\(result.sandboxPathUsed)\n"),
                      "TMPDIR must be the sandbox, got: \(result.infoOutput)")
        XCTAssertTrue(result.infoOutput.contains("path=/usr/bin:/bin:/usr/sbin:/sbin"),
                      "PATH must be fixed, not inherited, got: \(result.infoOutput)")
    }

    /// Declared environment — what a node's configuration passes — does reach the tool.
    /// It is an input, in the cache key like any other.
    func test_aDeclaredVariableReachesTheTool() throws {
        let result = try LocalFileSystemTool(localPath: "/bin/sh")
            .execute(arguments: ["-c", "echo \"declared=[$SEMEL_DECLARED]\""],
                     environment: ["SEMEL_DECLARED": "yes"],
                     inputFiles: [],
                     expectedOutputFileNames: [])

        XCTAssertTrue(result.infoOutput.contains("declared=[yes]"), "got: \(result.infoOutput)")
    }

    func test_aToolRunsInsideItsSandboxNotTheProcessWorkingDirectory() throws {
        let result = try runShell("pwd -P")

        XCTAssertEqual(result.exitCode, 0, result.errorOutput)
        let cwd = result.infoOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(cwd, result.sandboxPathUsed,
                       "the working directory must be the per-run sandbox")
        XCTAssertNotEqual(cwd, FileManager.default.currentDirectoryPath,
                          "the tool must not inherit where Semel itself is running")
    }

    /// The sandbox is gone when the tool is: nothing a tool leaves behind can be read by
    /// the next run.
    func test_theSandboxIsRemovedAfterTheRun() throws {
        let result = try runShell("echo leftover > leftover.txt")

        XCTAssertEqual(result.exitCode, 0, result.errorOutput)
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.sandboxPathUsed),
                       "the sandbox must be deleted once the tool has run")
    }
}
