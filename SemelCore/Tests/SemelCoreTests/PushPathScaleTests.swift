//
//  PushPathScaleTests.swift
//  SemelCore
//

@testable import SemelCore
@testable import SemelDatabaseModels
import Foundation
import GRDB
import SemelNodeKit
import XCTest

/// B-131. A push sends every file of a tree, and on a tree nobody edited every file is
/// already there. Resolved a select per path component, with a read of each folder's pin
/// beside it, a file six folders deep cost a dozen round trips through the serialised
/// database to find that nothing had changed — the IceCubes app's 8039 files took 15 s to
/// push unchanged. `StaticFile.push` answers an unchanged file in one select — the root,
/// the path below it with the folders' pins, and the file's ports — however deep it is.
///
/// Asserted in selects issued rather than in seconds, as `InputPortReadScaleTests` asserts
/// a port read: a count separates a lookup per component from one per path by the depth
/// of the tree, where a stopwatch has to be given a band wide enough to survive a loaded
/// machine. The seconds are carried for a failure message to quote, and are never asserted.
final class PushPathScaleTests: SemelCoreTestCase {

    /// The two trees: four times the files at four times the depth, so a cost that follows
    /// either shows up as a per-file count that moves, while a lookup per path stays put.
    private static let trees = (small: Tree(files: 40, depth: 2), large: Tree(files: 160, depth: 8))

    /// Selects an unchanged file may cost: the one that reads the root and the path below it.
    private static let selectsPerUnchangedFile = 1

    private var engine: BuildEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let database = try DatabaseLayer()
        engine = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    private var database: DatabaseLayer { engine.database }

    // MARK: - Growth

    func test_anUnchangedPushCostsTheSameSelectsPerFileHoweverDeepAndHoweverMany() throws {
        let small = try unchangedPush(of: Self.trees.small)
        let large = try unchangedPush(of: Self.trees.large)

        XCTAssertEqual(small.changed, 0, "nothing was edited — \(small.described)")
        XCTAssertEqual(large.changed, 0, "nothing was edited — \(large.described)")
        XCTAssertLessThanOrEqual(small.selects, small.tree.files * Self.selectsPerUnchangedFile, small.described)
        XCTAssertLessThanOrEqual(large.selects, large.tree.files * Self.selectsPerUnchangedFile, large.described)
        XCTAssertEqual(large.selectsPerFile, small.selectsPerFile,
                       "the selects an unchanged file costs must not follow the depth or the count — "
                       + "\(small.described); \(large.described)")
    }

    /// An unchanged push writes nothing, so it leaves nothing for a pass to rebuild.
    func test_anUnchangedPushMarksNoFolderAndRebuildsNoManifest() throws {
        try pushEveryFile(of: Self.trees.small)
        _ = try Folder.flushDirtyManifests()
        let rebuildsBefore = Folder.manifestRebuildCount.value

        try pushEveryFile(of: Self.trees.small)

        XCTAssertEqual(try dirtyKeys(), [], "no folder may be marked by a push that changed nothing")
        XCTAssertEqual(try Folder.flushDirtyManifests(), 0)
        XCTAssertEqual(Folder.manifestRebuildCount.value, rebuildsBefore)
    }

    // MARK: - What still changes

    /// The first file into a graph that has never held one: the port names the shortcut
    /// asks about are symbols such a graph has yet to record, and the root is one the
    /// cache may name from another graph. Neither may be read as a file already there.
    func test_theFirstPushIntoAFreshGraphIsWritten() throws {
        XCTAssertNil(try database.symbol.selectID(name: StaticFile.fileMetadataOutputPort),
                     "fixture: the graph has never recorded a file's port names")

        XCTAssertTrue(try push("first", mode: FileMetadata.defaultMode, at: Path("a/b/first.c")))
        XCTAssertEqual(try staticFile(at: Path("a/b/first.c")).read()?.expectValue(), try "first".intern())
        XCTAssertFalse(try push("first", mode: FileMetadata.defaultMode, at: Path("a/b/first.c")))
    }

    /// The shortcut answers for a file that has not changed and for nothing else: an edit
    /// is written, reported, and marks its folder for the next pass as it always did.
    func test_aPushThatChangesAFileStillWritesItAndMarksItsFolder() throws {
        let tree = Self.trees.small
        try pushEveryFile(of: tree)
        _ = try Folder.flushDirtyManifests()

        let edited = tree.path(ofFile: 7)
        XCTAssertTrue(try push("edited", mode: FileMetadata.defaultMode, at: edited))

        let file = try staticFile(at: edited)
        let hash = try XCTUnwrap(file.read()?.expectValue())
        XCTAssertEqual(hash, "edited".internedHash)
        XCTAssertEqual(try hash.resolve(), Array("edited".utf8), "the bytes of a change are stored, not only hashed")

        let folderID = try XCTUnwrap(engine.inputFileSystem.childNode(path: try XCTUnwrap(edited.deletingLastComponent))).requireID()
        XCTAssertEqual(try dirtyKeys(), ["\(Folder.manifestDirtyKeyPrefix)\(folderID)"],
                       "the edited file's folder, and only it, waits for the next pass")

        let rebuildsBefore = Folder.manifestRebuildCount.value
        XCTAssertEqual(try Folder.flushDirtyManifests(), 1)
        XCTAssertEqual(Folder.manifestRebuildCount.value, rebuildsBefore + 1)
    }

    /// The mode is half of what a push stores, so the same bytes under a new mode are a
    /// change, and the shortcut must not read them as the file it already holds.
    func test_aPushThatChangesOnlyTheModeIsAChange() throws {
        let path = Path("tools/run.sh")
        XCTAssertTrue(try push("echo", mode: FileMetadata.defaultMode, at: path))
        XCTAssertFalse(try push("echo", mode: FileMetadata.defaultMode, at: path))

        XCTAssertTrue(try push("echo", mode: 0o755, at: path))
        XCTAssertEqual(try staticFile(at: path).readFileMetadata()?.mode, 0o755)
    }

    /// An object store that lost the bytes a file's port still names is mended by pushing
    /// the file again: the shortcut asks after the object, and finding none it takes the
    /// full path, which stores it.
    func test_aPushOfAnUnchangedFileWhoseObjectIsGoneStoresItAgain() throws {
        let path = Path("mend/lost.c")
        XCTAssertTrue(try push("int lost;", mode: FileMetadata.defaultMode, at: path))

        let hash = "int lost;".internedHash
        try FileManager.default.removeItem(at: DataObjectStore.shared.objectURL(hash: hash))
        XCTAssertFalse(DataObjectStore.shared.exists(hash: hash), "fixture: the object is gone")

        XCTAssertFalse(try push("int lost;", mode: FileMetadata.defaultMode, at: path), "the port did not change")
        XCTAssertEqual(try hash.resolve(), Array("int lost;".utf8))
    }

    /// A folder on the way that is there but not pinned is pinned by the push, even when
    /// the file below it is unchanged: the shortcut reads the pin, and an unpinned folder is
    /// not the state it answers for.
    func test_aPushPinsAFolderOnTheWayThatIsNotPinnedEvenWhenTheFileIsUnchanged() throws {
        let path = Path("outer/inner/file.c")
        XCTAssertTrue(try push("int x;", mode: FileMetadata.defaultMode, at: path))

        let inner = try folder(at: "outer/inner")
        try inner.setPinned(false)
        XCTAssertFalse(try inner.isPinned, "fixture: the folder starts unpinned")

        XCTAssertFalse(try push("int x;", mode: FileMetadata.defaultMode, at: path),
                       "the bytes and the mode are as they were")
        XCTAssertTrue(try folder(at: "outer/inner").isPinned)
    }

    /// A path that names a file as a folder is refused as it always was, by the full path
    /// rather than read as unchanged by the shortcut.
    func test_aFileUnderAPathThatNamesAFileAsAFolderStillFails() throws {
        XCTAssertTrue(try push("a", mode: FileMetadata.defaultMode, at: Path("src/a.c")))

        XCTAssertThrowsError(try push("b", mode: FileMetadata.defaultMode, at: Path("src/a.c/b.c"))) { error in
            guard case NodeError.nameCollision(let path, let existingKind) = error else {
                return XCTFail("expected a name collision, got \(error)")
            }
            XCTAssertEqual(path, "\(Folder.inputFileSystemName)/src/a.c")
            XCTAssertEqual(existingKind, StaticFile.kind)
        }
    }

    // MARK: - The folders on the way

    /// `ensureEntirePathExistsAsFolders` reads an existing pinned path in one select, with
    /// the pins in it, however deep the path — `push folder` and every product placed in
    /// `output:` go through it too.
    func test_ensuringAnExistingPinnedPathIsOneSelectHoweverDeep() throws {
        let root = try engine.inputFileSystem
        for depth in [2, 8] {
            let path = Path((1...depth).map { "deep\(depth)-\($0)" }.joined(separator: "/"))
            try root.ensureEntirePathExistsAsFolders(path, pinned: true)

            let counts = SelectCounts()
            try root.ensureEntirePathExistsAsFolders(path, pinned: true)

            XCTAssertEqual(counts.nodeSelects, 1, "depth \(depth)")
            XCTAssertEqual(counts.portSelects, 0, "depth \(depth): the pins come with the path")
        }
    }

    /// A count alone cannot tell a lookup from a walk of every sibling, so the plan is read
    /// too: a step down the path has to be searched for through the index on both columns
    /// it is asked in.
    func test_aStepDownThePathIsAnIndexedLookup() throws {
        let plan = try database.dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN
                SELECT * FROM "Node" WHERE "parentNodeID" = ? AND "name" = ?
                """, arguments: [1, "src"])
                .map { $0["detail"] as String? ?? "" }
                .joined(separator: "\n")
        }

        XCTAssertTrue(plan.contains("SEARCH"), "a step must not scan the table, got: \(plan)")
        XCTAssertTrue(plan.contains("parentNodeID=? AND name=?"),
                      "both columns have to be the index's, got: \(plan)")
    }

    // MARK: - Pushing a tree

    /// N files at depth D: D folders to each file, the deepest one of four siblings, so
    /// consecutive files share their folders as the files of a real tree do.
    private struct Tree {
        let files: Int
        let depth: Int

        func path(ofFile index: Int) -> Path {
            let folders = (1..<depth).map { "level\($0)" } + ["leaf\(index % 4)"]
            return Path((folders + ["file\(index).swift"]).joined(separator: "/"))
        }

        func contents(ofFile index: Int) -> String {
            "let value\(index) = \(index)"
        }
    }

    /// What pushing a whole tree a second time cost: the selects it issued, how many files
    /// it reported changed, and the seconds, which are carried for a failure message to
    /// quote and are never asserted on.
    private struct UnchangedPush {
        let tree:    Tree
        let selects: Int
        let changed: Int
        let seconds: TimeInterval

        var selectsPerFile: Int { selects / tree.files }

        var described: String {
            "\(tree.files) files \(tree.depth) folders deep: \(selects) selects "
            + "(\(selectsPerFile) per file) in \(String(format: "%.3f", seconds))s"
        }
    }

    /// Pushes the tree, which is set-up and outside the count, then pushes it again as it
    /// is and counts that.
    private func unchangedPush(of tree: Tree) throws -> UnchangedPush {
        try pushEveryFile(of: tree)

        let counts = SelectCounts()
        let start  = Date.now
        let changed = try pushEveryFile(of: tree)

        return UnchangedPush(tree: tree, selects: counts.total, changed: changed,
                             seconds: Date.now.timeIntervalSince(start))
    }

    /// Returns how many of the pushes reported a change.
    @discardableResult
    private func pushEveryFile(of tree: Tree) throws -> Int {
        var changed = 0
        for index in 0..<tree.files {
            if try push(tree.contents(ofFile: index), mode: FileMetadata.defaultMode, at: tree.path(ofFile: index)) {
                changed += 1
            }
        }
        return changed
    }

    /// `text`, pushed as the server pushes a file's bytes.
    private func push(_ text: String, mode: UInt16, at relativePath: Path) throws -> Bool {
        try StaticFile.push(Array(text.utf8), mode: mode, at: relativePath)
    }

    /// The selects issued since this was made, against every table a push can read.
    private struct SelectCounts {
        private let nodeBefore = NodeDataAccess.selectCount.value
        private let portBefore = OutputPortDataAccess.selectCount.value
        private let wireBefore = WireDataAccess.selectCount.value

        var nodeSelects: Int { NodeDataAccess.selectCount.value - nodeBefore }
        var portSelects: Int { OutputPortDataAccess.selectCount.value - portBefore }
        var wireSelects: Int { WireDataAccess.selectCount.value - wireBefore }
        var total:       Int { nodeSelects + portSelects + wireSelects }
    }

    private func staticFile(at relativePath: Path) throws -> StaticFile {
        let node = try XCTUnwrap(engine.inputFileSystem.childNode(path: relativePath))
        return try XCTUnwrap(node.nodeAsAny() as? StaticFile)
    }

    private func folder(at relativePath: String) throws -> Folder {
        let node = try XCTUnwrap(engine.inputFileSystem.childNode(path: Path(relativePath)))
        return try XCTUnwrap(node.nodeAsAny() as? Folder)
    }

    private func dirtyKeys() throws -> [String] {
        try database.metadata.selectKeys(withPrefix: Folder.manifestDirtyKeyPrefix)
    }
}
