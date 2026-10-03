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

    // MARK: - One fold per folder

    /// A new tree is folded once per folder and value, however deep: the flush folds the
    /// deepest marked folder first, so the mark a folder leaves on the one above is
    /// cleared by that one's fold in the same round rather than refolding it in the next.
    /// Each fold is a document written to the object store.
    func test_aNewTreeIsFoldedOncePerFolderWhateverItsDepth() throws {
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
        try pushBatch(Self.files)

        let manifests    = Folder.manifestRebuildCount.value
        let roots        = Folder.contentRootRebuildCount.value
        let subtrees     = Folder.subtreeManifestRebuildCount.value
        try Folder.flushDirtyManifests()

        XCTAssertEqual(Folder.manifestRebuildCount.value - manifests, Self.folders.count)
        XCTAssertEqual(Folder.contentRootRebuildCount.value - roots, Self.folders.count)
        XCTAssertEqual(Folder.subtreeManifestRebuildCount.value - subtrees, Self.folders.count)
    }

    // MARK: - What a push writes to the object store

    /// A push of a nested new tree stores each object it needs once and touches again only
    /// the ones it shares: a folder is made with nothing interned for its folds, which its
    /// first fold publishes, and a file is made with the metadata it is pushed with.
    ///
    /// Four files with distinct bytes, default mode, in five new folders. Written: the four
    /// files' bytes, the one metadata document they share, and the `true` the folders are
    /// pinned with. Touched: that metadata document by the three files after the first, and
    /// `true` by the four folders after the first. A folder made with an empty manifest of
    /// its own wrote one per folder, and a file made with the default metadata touched that
    /// document a second time.
    func test_aPushOfANestedNewTreeStoresEachObjectOnce() throws {
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
        _ = try engine.inputFileSystem

        let before = DataObjectStore.shared.writes
        try pushBatch([("a/b/c/one.c", "one"), ("a/b/two.c", "two"), ("a/d/three.c", "three"), ("g/four.c", "four")])
        let after  = DataObjectStore.shared.writes

        XCTAssertEqual(after.written - before.written, 6)
        XCTAssertEqual(after.touched - before.touched, 7)
    }

    // MARK: - A new folder before its first fold

    /// A folder a push makes holds no fold until the flush, and is marked for one, so a
    /// read of its manifest before then folds it and is handed what the flush publishes: a
    /// manifest naming what the push put in it.
    func test_aNewFoldersManifestReadBeforeTheFlushIsItsFold() throws {
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
        try pushBatch([("new/inner/one.c", "one"), ("new/two.c", "two")])

        let record = try XCTUnwrap(try engine.inputFileSystem.childNode(path: "new"))
        let read   = try record.readFromOutputPort(Folder.folderManifestOutputPort).expectValue()
        let manifest: FolderManifest = try TypeRegistry.decodeAndCast(encodedJSON: try read.resolveAsString())
        XCTAssertEqual(manifest.entries.map(\.name).sorted(), ["inner", "two.c"])

        try Folder.flushDirtyManifests()
        XCTAssertEqual(try record.readFromOutputPort(Folder.folderManifestOutputPort).expectValue(), read,
                       "the flush publishes what the read was handed")
    }

    /// A folder made on the way with nothing placed in it — a symbolic link pushed as a
    /// folder — is marked all the same, and reads as a folder with nothing in it: the
    /// listing and the empty tree's root it was made with before its folds were left to
    /// the flush.
    func test_aFolderMadeWithNothingPlacedInItReadsAsAnEmptyFolder() throws {
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
        _ = try Folder.pushSymbolicLink(target: "elsewhere", at: Path("linked"))

        let record = try XCTUnwrap(try engine.inputFileSystem.childNode(path: "linked"))
        let manifest: FolderManifest = try TypeRegistry.decodeAndCast(
            encodedJSON: try record.readFromOutputPort(Folder.folderManifestOutputPort).expectValue().resolveAsString())
        XCTAssertTrue(manifest.entries.isEmpty)
        XCTAssertEqual(manifest.baseFolderPath, "input:/linked")
        XCTAssertEqual(try record.readFromOutputPort(Folder.contentRootOutputPort).expectValue(),
                       try FolderContentRoot.document(of: []).internedHash)
    }

    // MARK: - A fold that throws

    /// A fold that throws in the middle of a flush is undone, mark and all: the folder
    /// stays marked, its port keeps what it held, and the folds beside it publish. The
    /// flush itself does not throw, and the next one folds it once it can.
    ///
    /// The fold made to throw is a content root's: it reads each file's metadata document,
    /// and the one an executable file is pushed with is damaged in the store.
    func test_aFoldThatThrowsLeavesItsFolderMarkedAndPublishesNothing() throws {
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
        let database = engine.database
        _ = try StaticFile.push(Array("run".utf8), mode: 0o755, at: Path("broken/run.sh"))
        _ = try StaticFile.push(Array("ok".utf8), mode: FileMetadata.defaultMode, at: Path("fine/ok.c"))

        let broken     = try XCTUnwrap(try engine.inputFileSystem.childNode(path: "broken"))
        let fine       = try XCTUnwrap(try engine.inputFileSystem.childNode(path: "fine"))
        let brokenID   = try broken.requireID()
        let rootSymbol = Folder.contentRootOutputPort.asSymbolID()
        let markKey    = "\(Folder.contentRootDirtyKeyPrefix)\(brokenID)"
        let heldBefore = try database.outputPort.select(nodeID: brokenID, nameSymbolID: rootSymbol)

        let metadata = try StaticFile.metadataValue(mode: 0o755).expectValue()
        let object   = DataObjectStore.shared.objectURL(hash: metadata)
        let original = try Data(contentsOf: object)
        try damage(object, with: Data("damaged".utf8))

        XCTAssertNoThrow(try Folder.flushDirtyManifests())

        XCTAssertNotNil(try database.metadata.select(key: markKey), "the folder stays marked")
        XCTAssertEqual(try database.outputPort.select(nodeID: brokenID, nameSymbolID: rootSymbol), heldBefore,
                       "and publishes nothing new")
        XCTAssertNoThrow(try fine.readFromOutputPort(Folder.contentRootOutputPort).expectValue())
        XCTAssertNoThrow(try broken.readFromOutputPort(Folder.folderManifestOutputPort).expectValue(),
                         "the folds that do not read the damaged document publish")
        let held = Dictionary(uniqueKeysWithValues: try HeldTree.folderRoots(below: .empty).map { ($0.path.string, $0) })
        XCTAssertNil(try XCTUnwrap(held["broken"]).contentRoot, "no root is offered for the marked folder")
        XCTAssertNil(try XCTUnwrap(held[""]).contentRoot, "nor for the folder above it")
        XCTAssertNotNil(try XCTUnwrap(held["fine"]).contentRoot)

        XCTAssertThrowsError(try broken.readFromOutputPort(Folder.contentRootOutputPort))
        XCTAssertNotNil(try database.metadata.select(key: markKey), "a read that fails leaves the mark too")

        try damage(object, with: original)
        try Folder.flushDirtyManifests()

        XCTAssertNil(try database.metadata.select(key: markKey))
        XCTAssertNoThrow(try broken.readFromOutputPort(Folder.contentRootOutputPort).expectValue())
    }

    // MARK: - Helpers

    /// `files` pushed in one transaction, a savepoint per file, as a request records a batch.
    private func pushBatch(_ files: [(path: String, content: String)]) throws {
        try DatabaseLayer.shared.withTransactionPerStep {
            for file in files {
                do {
                    _ = try StaticFile.push(Array(file.content.utf8), mode: FileMetadata.defaultMode, at: Path(file.path))
                } catch {
                    continue
                }
            }
        }
    }

    /// Replaces a stored object's bytes, which the store keeps read-only.
    private func damage(_ object: URL, with bytes: Data) throws {
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: object.path)
        try bytes.write(to: object)
    }

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
