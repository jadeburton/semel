//
//  FolderBatchFoldTests.swift
//  SemelCore
//

@testable import SemelCore
@testable import SemelDatabaseModels
import Foundation
import SemelNodeKit
import XCTest

/// A push records a batch of files in one transaction (`withTransactionPerStep`), making
/// the folders on the way to each as it goes. A folder is made with the fold over no
/// children, without reading any (`Folder.didCreate`), and the files it is then given mark
/// it, so it is folded once, after the batch, over all of them. What it publishes then has
/// to be exactly what folding after every file publishes: the manifest every consumer
/// reads, the content root a push compares with the disk (B-132), and the subtree manifest.
final class FolderBatchFoldTests: SemelCoreTestCase {

    /// The files of one push in the order a client sends them, new folders nested several
    /// deep and one file refused in the middle: `a/b/two.c` is a file, so a path through it
    /// asks for a folder where a file stands.
    private static let files: [(path: String, content: String)] = [
        ("a/b/c/one.c",       "one"),
        ("a/b/two.c",         "two"),
        ("a/d/three.c",       "three"),
        ("a/b/two.c/x.c",     "refused"),
        ("a/b/c/e/four.c",    "four"),
        ("a/b/c/e/f/five.c",  "five"),
        ("g/six.c",           "six"),
        ("a/b/c/e/seven.c",   "seven"),
    ]

    /// Every folder the push makes, and the input root above them.
    private static let folders = ["", "a", "a/b", "a/b/c", "a/b/c/e", "a/b/c/e/f", "a/d", "g"]

    private var engine: BuildEngine!

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    func test_aBatchFoldedOnceAfterwardsPublishesWhatFoldingAfterEveryFilePublishes() throws {
        let perFile = try published { refused in
            for file in Self.files {
                do {
                    try DatabaseLayer.shared.withTransaction {
                        _ = try StaticFile.push(Array(file.content.utf8), mode: FileMetadata.defaultMode, at: Path(file.path))
                    }
                } catch {
                    refused.append(file.path)
                }
                try Folder.flushDirtyManifests()
            }
        }

        let batched = try published { refused in
            try DatabaseLayer.shared.withTransactionPerStep {
                for file in Self.files {
                    do {
                        _ = try StaticFile.push(Array(file.content.utf8), mode: FileMetadata.defaultMode, at: Path(file.path))
                    } catch {
                        refused.append(file.path)
                    }
                }
            }
            try Folder.flushDirtyManifests()
        }

        XCTAssertEqual(perFile.refused, ["a/b/two.c/x.c"], "fixture: one file refused")
        XCTAssertEqual(batched.refused, perFile.refused)
        for folder in Self.folders {
            XCTAssertEqual(batched.values[folder], perFile.values[folder], "folder '\(folder)'")
        }
    }

    /// The fold a folder is made with is the one a fold over its children gives while it
    /// has none: folding it again straight away writes nothing.
    func test_aFolderIsMadeWithTheFoldOfAFolderWithNothingInIt() throws {
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine

        let record = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(Path("empty/inner"), pinned: true)
        let folder = try XCTUnwrap(try record.makeNode() as? Folder)
        let made   = try values(of: folder)

        try folder.refreshOutputs()

        XCTAssertEqual(try values(of: folder), made)
        XCTAssertEqual(made[Folder.contentRootOutputPort], try FolderContentRoot.document(of: []).internedHash,
                       "an empty folder's root is the empty tree's, wherever it stands")
    }

    // MARK: - Helpers

    /// What every folder of `folders` publishes after `push` has run against a graph of its
    /// own, with the paths it refused.
    private func published(_ push: (inout [String]) throws -> Void) throws -> (values: [String: [String: String]],
                                                                                refused: [String]) {
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine

        var refused: [String] = []
        try push(&refused)

        var values: [String: [String: String]] = [:]
        for path in Self.folders {
            let record = try XCTUnwrap(try engine.inputFileSystem.childNode(path: path.isEmpty ? .empty : Path(path)), path)
            values[path] = try self.values(of: try XCTUnwrap(try record.makeNode() as? Folder, path))
        }
        return (values, refused)
    }

    /// The folder's three folds and its pin, by port.
    private func values(of folder: Folder) throws -> [String: String] {
        var values: [String: String] = [:]
        for port in [Folder.folderManifestOutputPort, Folder.contentRootOutputPort,
                     Folder.subtreeManifestOutputPort, Folder.pinnedOutputPort] {
            values[port] = "\(try folder.thisNode.readFromOutputPort(port))"
        }
        values[Folder.contentRootOutputPort] = try folder.thisNode.readFromOutputPort(Folder.contentRootOutputPort).expectValue()
        return values
    }
}
