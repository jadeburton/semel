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

    // MARK: - Output folders (B-63)

    /// A tool that decides its own file set writes a folder; every file under it, at any
    /// depth, comes back with its path below the folder and its mode, so an executable
    /// inside a tree stays one. The order is the sorted path order, whatever the file
    /// system's, so the tree a node builds from them is one value.
    func test_everyFileOfAnExpectedOutputFolderComesBackWithPathAndMode() throws {
        let result = try LocalFileSystemTool(localPath: "/bin/sh")
            .execute(arguments: ["-c", """
                mkdir -p out/en.lproj out/zz && printf car > out/Assets.car && \
                printf strings > out/en.lproj/Localizable.strings && printf run > out/zz/tool && chmod 755 out/zz/tool
                """],
                     environment: [:],
                     inputFiles: [],
                     expectedOutputFileNames: [],
                     expectedOutputFolders: ["out"])

        XCTAssertEqual(result.exitCode, 0, result.errorOutput)
        let files = try XCTUnwrap(result.outputTrees["out"])
        XCTAssertEqual(files.map(\.relativePath), ["Assets.car", "en.lproj/Localizable.strings", "zz/tool"])
        XCTAssertEqual(files.map { String(decoding: $0.data, as: UTF8.self) }, ["car", "strings", "run"])
        XCTAssertEqual(files.map(\.mode), [0o644, 0o644, 0o755])
    }

    /// `actool --compile <dir>` writes into a directory it does not create, so an expected
    /// output folder is there before the tool runs; one the tool leaves empty is an empty
    /// tree, which is a value.
    func test_anExpectedOutputFolderExistsWhenTheToolRunsAndMayStayEmpty() throws {
        let result = try LocalFileSystemTool(localPath: "/bin/sh")
            .execute(arguments: ["-c", "test -d out && test -d nested/deeper"],
                     environment: [:],
                     inputFiles: [],
                     expectedOutputFileNames: [],
                     expectedOutputFolders: ["out", "nested/deeper"])

        XCTAssertEqual(result.exitCode, 0, "the folders must exist before the tool runs: \(result.errorOutput)")
        XCTAssertEqual(result.outputTrees["out"]?.count ?? 0, 0)
        XCTAssertTrue(result.errorOutput.isEmpty, result.errorOutput)
    }

    /// The sandbox is gone when the tool is: nothing a tool leaves behind can be read by
    /// the next run.
    func test_theSandboxIsRemovedAfterTheRun() throws {
        let result = try runShell("echo leftover > leftover.txt")

        XCTAssertEqual(result.exitCode, 0, result.errorOutput)
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.sandboxPathUsed),
                       "the sandbox must be deleted once the tool has run")
    }

    /// Phase 1 runs every ready node concurrently, so tools launch from many threads at
    /// once. A pipe's write end that stays open in the parent — Foundation does not close
    /// it reliably under concurrent launches — or that a sibling child inherits before its
    /// own spawn keeps the reader waiting for an EOF that never comes: the first IceCubes
    /// build with 86 ready nodes hung with every tool exited and every thread in
    /// `readDataToEndOfFile`. The runner closes its own write ends and marks the pipes
    /// close-on-exec, and this pins it: two dozen concurrent runs all come back.
    func test_manyConcurrentRunsAllComeBack() throws {
        let expectation = expectation(description: "every concurrent tool run returns")
        expectation.expectedFulfillmentCount = 24

        var failures: [String] = []
        let lock = NSLock()

        for index in 0..<24 {
            DispatchQueue.global().async {
                do {
                    // Staggered durations and more than a pipe buffer of output on both
                    // streams, so launches overlap the way real compiles do.
                    let result = try self.runShell("""
                        sleep 0.\(index % 5); head -c 100000 /dev/zero | tr '\\0' x; echo run\(index); \
                        head -c 100000 /dev/zero | tr '\\0' y 1>&2; echo err\(index) 1>&2
                        """)
                    if result.exitCode != 0 || !result.infoOutput.contains("run\(index)") || !result.errorOutput.contains("err\(index)") {
                        lock.lock(); failures.append("run \(index): \(result.exitCode) \(result.infoOutput) \(result.errorOutput)"); lock.unlock()
                    }
                } catch {
                    lock.lock(); failures.append("run \(index): \(error)"); lock.unlock()
                }
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 30)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}
