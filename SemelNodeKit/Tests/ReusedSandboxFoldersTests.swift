//
//  ReusedSandboxFoldersTests.swift
//  SemelNodeKit
//
//  A tool whose daemon stays in the folder a run had runs in a sandbox folder that is
//  emptied and reused, never removed (B-152): the folder outlives the run, starts each run
//  empty, and is one run's at a time.
//

@testable import SemelNodeKit
import Foundation
import XCTest

final class ReusedSandboxFoldersTests: XCTestCase {

    private var userStore: DataObjectStore!
    private var parent: URL!

    override func setUp() {
        super.setUp()
        userStore = DataObjectStore.shared
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-reused-sandbox-tests/\(UUID().uuidString)", isDirectory: true)
        DataObjectStore.shared = DataObjectStore(storeRoot: root.appendingPathComponent("store", isDirectory: true))
        parent = root.appendingPathComponent("sandboxes", isDirectory: true)
    }

    override func tearDown() {
        DataObjectStore.shared = userStore
        try? FileManager.default.removeItem(at: parent.deletingLastPathComponent())
        super.tearDown()
    }

    private func run(_ script: String, inputs: [FileNameAndContent] = []) throws -> SimplifiedToolExecuteResult {
        try LocalFileSystemTool(localPath: "/bin/sh", reusingSandboxFoldersUnder: parent)
            .execute(arguments: ["-c", script], environment: [:], inputFiles: inputs, expectedOutputFileNames: [])
    }

    /// Two runs one after the other run in one folder, which is there after each, and
    /// empty: what a run left — a hidden file too — is not what the next one finds.
    func test_theFolderOutlivesTheRunAndStartsEachRunEmpty() throws {
        let first = try run("pwd -P; touch left.txt .hidden; ls -A",
                            inputs: [FileNameAndContent(filePath: "in/a.txt", hash: try "a".intern())])
        let second = try run("pwd -P; ls -A")

        let folder = first.resolvedSandboxPath
        XCTAssertTrue(folder.hasSuffix("/slot-0"), folder)
        XCTAssertTrue(first.infoOutput.hasPrefix(folder + "\n"), first.infoOutput)
        XCTAssertTrue(first.infoOutput.contains("left.txt"), first.infoOutput)
        XCTAssertTrue(second.infoOutput.hasPrefix(folder + "\n"), second.infoOutput)
        XCTAssertFalse(second.infoOutput.contains("left.txt"), "a run finds nothing of the one before: \(second.infoOutput)")
        XCTAssertFalse(second.infoOutput.contains("in"), second.infoOutput)
        var isFolder: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder) && isFolder.boolValue)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder), [])
    }

    /// The working directory is the folder, which is what the daemon follows, and HOME and
    /// TMPDIR are the folder, as they are a temporary sandbox.
    func test_theToolRunsInTheFolder() throws {
        let result = try run(#"echo "home=$(cd "$HOME" && pwd -P)"; echo "here=$(pwd -P)""#)

        XCTAssertTrue(result.infoOutput.contains("home=\(result.resolvedSandboxPath)\n"), result.infoOutput)
        XCTAssertTrue(result.infoOutput.contains("here=\(result.resolvedSandboxPath)\n"), result.infoOutput)
        XCTAssertTrue(result.resolvedSandboxPath.hasSuffix("/slot-0"), result.resolvedSandboxPath)
    }

    /// A slot another run holds is passed over, by its lock, whichever process holds it.
    func test_aSlotHeldByAnotherRunIsPassedOver() throws {
        let folders = ReusedSandboxFolders(parent: parent)
        let held = try folders.take()
        defer { folders.give(back: held) }

        let result = try run("pwd -P")

        XCTAssertTrue(held.folder.path.hasSuffix("/slot-0"))
        XCTAssertTrue(result.resolvedSandboxPath.hasSuffix("/slot-1"), result.resolvedSandboxPath)
    }
}
