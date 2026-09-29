//
//  FolderMerkleRootTests.swift
//  SemelCore
//

@testable import SemelCore
import SemelNodeKit
import XCTest

/// B-26. A folder's `contentRoot` port carries a Merkle root: the hash of a document with
/// one line per child, a file's line carrying its bytes and a subfolder's carrying that
/// subfolder's own root — so one hash identifies a whole tree.
///
/// Three properties are asserted here and nowhere else. That a change anywhere below a
/// folder moves that folder's root; that the root follows the content rather than the order
/// the content arrived in, which is what makes two copies of one tree comparable at all;
/// and that the root is a value of its own, so the `manifest` port — which nearly
/// everything downstream of a folder is wired to — does not move when a file is edited.
final class FolderMerkleRootTests: SemelCoreTestCase {

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

    // MARK: - A content change moves the root

    func test_aFileContentChangeMovesItsFoldersRoot() throws {
        try push("flat/a.c", contents: "int a;")
        try push("flat/b.c", contents: "int b;")
        let before = try root(of: "flat")

        try push("flat/a.c", contents: "int a = 1;")
        try Folder.flushDirtyManifests()

        XCTAssertNotEqual(try root(of: "flat"), before,
                          "a file's content is folded into its folder's root, so the hash has to move")
    }

    /// The fold is what carries a change up: the grandchild's hash is in its folder's root,
    /// and that root is in the line for that folder in the folder above it.
    func test_aGrandchildContentChangeMovesTheRootAboveIt() throws {
        try push("deep/mid/leaf/f.c", contents: "int f;")
        try Folder.flushDirtyManifests()
        let before = try root(of: "deep")

        try push("deep/mid/leaf/f.c", contents: "int f = 2;")
        try Folder.flushDirtyManifests()

        XCTAssertNotEqual(try root(of: "deep"), before, "the change has to reach every ancestor")
    }

    func test_aFileContentChangeDoesNotMoveASiblingFoldersRoot() throws {
        try push("one/f.c", contents: "1")
        try push("two/g.c", contents: "2")
        try Folder.flushDirtyManifests()
        let untouched = try root(of: "two")

        try push("one/f.c", contents: "1 changed")
        try Folder.flushDirtyManifests()

        XCTAssertEqual(try root(of: "two"), untouched, "nothing under it changed")
    }

    // MARK: - The manifest is names, and stays still

    /// The reason the root is a port of its own. `ProjectFinder` is wired to the manifest of
    /// `input:`, and a converter to the manifest of each target folder; if content were
    /// folded into that value, every one of them would re-run on every keystroke.
    func test_aFileContentChangeLeavesEveryAncestorManifestAlone() throws {
        try push("stable/mid/f.c", contents: "int f;")
        try Folder.flushDirtyManifests()
        let manifests = try ["", "stable", "stable/mid"].map { try manifestHash(of: $0) }

        try push("stable/mid/f.c", contents: "int f = 3;")
        try Folder.flushDirtyManifests()

        XCTAssertEqual(try ["", "stable", "stable/mid"].map { try manifestHash(of: $0) }, manifests,
                       "an edit changes no folder's list of children")
    }

    /// A file's *state* is in the manifest, through `isPinned`, so removing one does move
    /// the manifest of the folder holding it — and still no manifest above that one.
    func test_aRemovalMovesTheHoldingFoldersManifestAndNoOtherFoldersManifest() throws {
        try push("removal/mid/f.c", contents: "f")
        try Folder.flushDirtyManifests()
        let above = try ["", "removal"].map { try manifestHash(of: $0) }
        let holding = try manifestHash(of: "removal/mid")

        let file = try XCTUnwrap(try engine.inputFileSystem.childNode(path: "removal/mid/f.c")?.nodeAsAny() as? StaticFile)
        _ = try file.replaceContent(nil as DataObjectHash?)
        try Folder.flushDirtyManifests()

        XCTAssertNotEqual(try manifestHash(of: "removal/mid"), holding, "the file is no longer pinned")
        XCTAssertEqual(try ["", "removal"].map { try manifestHash(of: $0) }, above)
    }

    /// What the manifest holding still is worth, said in the terms that cost time: the node
    /// wired to `input:`'s manifest is not woken by an edit three folders down. Editing a
    /// source is the per-keystroke path, and `ProjectFinder` decodes every watched folder's
    /// manifest each time it runs.
    func test_anEditDoesNotWakeAConsumerOfAnAncestorsManifest() throws {
        // ProjectFinder wires itself to the root manifest when it first processes.
        try engine.projectFinder.makeNode().processWithPreCheck()
        try push("pkg/main.swift", contents: "print(1)")
        try Folder.flushDirtyManifests()
        try engine.projectFinder.setScheduled(false)

        try push("pkg/main.swift", contents: "print(2)")
        try Folder.flushDirtyManifests()

        XCTAssertFalse(try projectFinderIsScheduled(), "an edit is not a change to the file set")
    }

    /// And the same consumer still wakes for what it is there for, so the test above is not
    /// passing because nothing is wired.
    func test_aNewFileDoesWakeAConsumerOfAnAncestorsManifest() throws {
        try engine.projectFinder.makeNode().processWithPreCheck()
        try push("pkg/main.swift", contents: "print(1)")
        try Folder.flushDirtyManifests()
        try engine.projectFinder.setScheduled(false)

        try push("second.swift", contents: "print(2)")
        try Folder.flushDirtyManifests()

        XCTAssertTrue(try projectFinderIsScheduled(), "a name appeared at the root it watches")
    }

    // MARK: - The root follows the content, not the order it arrived in

    /// The same names with the same contents give the same hash whichever order they were
    /// pushed in.
    func test_pushOrderDoesNotChangeTheRoot() throws {
        for name in ["a.c", "b.c", "c.c"] {
            try push("order/\(name)", contents: "contents of \(name)")
        }
        try Folder.flushDirtyManifests()
        let forwards = try root(of: "order")

        try removeEverythingUnder("order")

        for name in ["c.c", "b.c", "a.c"] {
            try push("order/\(name)", contents: "contents of \(name)")
        }
        try Folder.flushDirtyManifests()

        XCTAssertEqual(try root(of: "order"), forwards, "the hash is over the content, not the row order")
    }

    /// The document says what is in the folder and never where the folder is, so the same
    /// tree at two paths has one root. `baseFolderPath` is in the manifest and this is why
    /// the root is not a field of it: a lock recorded against a vendored dependency (B-06)
    /// survives that dependency being moved.
    func test_theSameTreeAtTwoPathsHasOneRoot() throws {
        try push("here/pkg/f.c", contents: "int f;")
        try push("here/pkg/g.c", contents: "int g;")
        try push("elsewhere/deeper/pkg/f.c", contents: "int f;")
        try push("elsewhere/deeper/pkg/g.c", contents: "int g;")
        try Folder.flushDirtyManifests()

        XCTAssertEqual(try root(of: "here/pkg"), try root(of: "elsewhere/deeper/pkg"))
        XCTAssertNotEqual(try manifestHash(of: "here/pkg"), try manifestHash(of: "elsewhere/deeper/pkg"),
                          "the manifests differ, because a manifest names the folder it describes")
    }

    func test_twoEmptyFoldersHaveOneRoot() throws {
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(Path("empty/one"), pinned: true)
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(Path("empty/two"), pinned: true)

        XCTAssertEqual(try root(of: "empty/one"), try root(of: "empty/two"))
    }

    // MARK: - What a line carries

    func test_aFilesLineCarriesItsContentHash() throws {
        let hash = try "int a;".intern()
        try push("entry/a.c", contents: "int a;")

        let text = try document(of: "entry")
        XCTAssertTrue(text.contains("file\thash \(hash)\t3\ta.c\n"), text)
    }

    func test_aSubfoldersLineCarriesItsOwnRoot() throws {
        try push("parent/child/f.c", contents: "f")
        try Folder.flushDirtyManifests()

        let childRoot = try root(of: "parent/child")
        let text = try document(of: "parent")
        XCTAssertTrue(text.contains("folder\thash \(childRoot)\t5\tchild\n"), text)
    }

    // MARK: - Links (B-77)

    /// A file pushed as a link is a `link` line holding its target, never the bytes it
    /// carries; a folder pushed as one is a `link` line too, whatever the copy of what it
    /// names below it holds. And the folder's manifest says the subfolder is a link, so a
    /// walk building a tree knows before it descends.
    func test_aLinkFoldsAsItsTargetAndAFolderLinkIsListedAsOne() throws {
        try push("fw/Versions/A/Tiny", contents: "binary")
        try push("fw/Versions/Current/Tiny", contents: "binary")
        XCTAssertTrue(try Folder.pushSymbolicLink(target: "A", at: "fw/Versions/Current"))
        XCTAssertTrue(try StaticFile.push(Array("binary".utf8), mode: 0o755, symbolicLinkTarget: "Versions/Current/Tiny", at: "fw/Tiny"))
        try Folder.flushDirtyManifests()

        let framework = try document(of: "fw")
        let versions  = try document(of: "fw/Versions")
        XCTAssertTrue(framework.contains("link\ttarget 21 Versions/Current/Tiny\t4\tTiny\n"), framework)
        XCTAssertTrue(versions.contains("link\ttarget 1 A\t7\tCurrent\n"), versions)
        let manifest: FolderManifest = try TypeRegistry.decodeAndCast(encodedJSON: try manifestHash(of: "fw/Versions").resolveAsString())
        XCTAssertEqual(manifest.entries.map { "\($0.name)=\($0.symbolicLinkTarget ?? "-")" }, ["A=-", "Current=A"])
    }

    /// Retargeting a link moves the root, and pushing it again as it was moves nothing.
    func test_retargetingALinkMovesTheRoot() throws {
        try push("pkg/Real.txt", contents: "same")
        try push("pkg/Other.txt", contents: "same")
        _ = try StaticFile.push(Array("same".utf8), mode: 0o644, symbolicLinkTarget: "Real.txt", at: "pkg/Alias.txt")
        try Folder.flushDirtyManifests()
        let linked = try root(of: "pkg")

        XCTAssertFalse(try StaticFile.push(Array("same".utf8), mode: 0o644, symbolicLinkTarget: "Real.txt", at: "pkg/Alias.txt"))
        _ = try StaticFile.push(Array("same".utf8), mode: 0o644, symbolicLinkTarget: "Other.txt", at: "pkg/Alias.txt")
        try Folder.flushDirtyManifests()

        XCTAssertNotEqual(try root(of: "pkg"), linked)
    }

    /// A child with no content is a state rather than a missing hash, and the states are
    /// kept apart: a folder a file was removed from is not a folder that never held it.
    func test_aRemovedChildIsAStateAndNotAHash() throws {
        try push("ghost/f.c", contents: "f")
        try Folder.flushDirtyManifests()

        let file = try XCTUnwrap(try engine.inputFileSystem.childNode(path: "ghost/f.c")?.nodeAsAny() as? StaticFile)
        _ = try file.replaceContent(nil as DataObjectHash?)
        try Folder.flushDirtyManifests()

        let text = try document(of: "ghost")
        XCTAssertTrue(text.contains("file\tdeleted\t3\tf.c\n"), text)
    }

    func test_aFileNobodyPushedIsNotTheSameAsOneThatWasRemoved() throws {
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(Path("named"), pinned: true)
        let fullPath = Path(Folder.inputFileSystemName) / Path("named/never.c")
        _ = try GraphSpecNode.parse("StaticFile(path: '\(fullPath.string)')").findOrCreateMatchingNode()
        try Folder.flushDirtyManifests()

        let text = try document(of: "named")
        XCTAssertTrue(text.contains("file\tnot-produced\t7\tnever.c\n"), text)
    }

    /// A hash does not say what it is a hash of, so the kind is on the line. An empty
    /// folder's document is bytes like any other: a file holding exactly those bytes interns
    /// to the hash that folder's entry would carry, and without the kind the two children
    /// write one line.
    func test_aFileWhoseBytesAreAnEmptyFoldersDocumentDoesNotFoldAsThatFolder() throws {
        let emptyFolderDocument = FolderContentRoot.document(of: [])
        try push("impostor/x", contents: emptyFolderDocument)
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(Path("genuine/x"), pinned: true)
        try Folder.flushDirtyManifests()

        XCTAssertEqual(try root(of: "genuine/x"), try emptyFolderDocument.intern(),
                       "precondition: the file's bytes hash to what the empty folder's entry carries")
        XCTAssertNotEqual(try root(of: "impostor"), try root(of: "genuine"),
                          "a file and a folder of one name must not fold alike")
    }

    /// The name is last on its line and framed by its byte length, so a name that reads as a
    /// whole line of its own changes the root rather than the shape of the document.
    func test_aNameHoldingAWholeLineCannotBeConfusedWithTwoEntries() throws {
        let sneaky = FolderContentRoot.document(of: [("a\nfile\tnot-produced\t1\tb", .file, .notProduced)])
        let twoEntries = FolderContentRoot.document(of: [("a", .file, .notProduced),
                                                         ("b", .file, .notProduced)])

        XCTAssertNotEqual(sneaky, twoEntries)
    }

    /// Two children of one name are ordered by kind, so the document does not depend on
    /// which row the database returned first.
    func test_twoChildrenOfOneNameAreOrderedByKind() throws {
        let oneWay = FolderContentRoot.document(of: [("x", .folder, .notProduced),
                                                     ("x", .file, .notProduced)])
        let theOther = FolderContentRoot.document(of: [("x", .file, .notProduced),
                                                       ("x", .folder, .notProduced)])

        XCTAssertEqual(oneWay, theOther)
    }

    // MARK: - Cost

    /// An edit folds one root per folder on the path from the file to the root, and touches
    /// no other folder: the cost of reaching every consumer is the depth of the tree, not
    /// its size. And it rebuilds no manifest at all, which is the whole point of the split.
    func test_anEditFoldsOneRootPerAncestorAndRebuildsNoManifest() throws {
        for index in 0..<40 {
            try push("wide/sibling\(index)/f.c", contents: "\(index)")
        }
        try push("wide/deep/mid/leaf/f.c", contents: "start")
        try Folder.flushDirtyManifests()

        let manifestsBefore = Folder.manifestRebuildCount.value
        let rootsBefore     = Folder.contentRootRebuildCount.value
        try push("wide/deep/mid/leaf/f.c", contents: "changed")
        try Folder.flushDirtyManifests()
        let manifests = Folder.manifestRebuildCount.value - manifestsBefore
        let roots     = Folder.contentRootRebuildCount.value - rootsBefore

        // input: / wide / deep / mid / leaf — five folders on the path, and nothing else.
        XCTAssertEqual(roots, 5, "folded \(roots) roots for one file in a tree of 41 folders")
        // The file's holding folder is marked by the push, as it was before B-26; no
        // ancestor's manifest is touched.
        XCTAssertEqual(manifests, 1, "rebuilt \(manifests) manifests for a change no manifest shows")
    }

    /// Not an assertion, a measurement: what one edit costs at the scale the B-25 tests use.
    func test_measureEditCostAtScale() throws {
        for index in 0..<3000 {
            try push("scale/dir\(index / 100)/file\(index).c", contents: "int f\(index);")
        }
        try Folder.flushDirtyManifests()

        let manifestsBefore = Folder.manifestRebuildCount.value
        let rootsBefore     = Folder.contentRootRebuildCount.value
        let start = Date.now
        try push("scale/dir0/file0.c", contents: "changed")
        try Folder.flushDirtyManifests()
        let seconds = Date.now.timeIntervalSince(start)

        print("B-26 measure: 3000 files, one edit rebuilt \(Folder.manifestRebuildCount.value - manifestsBefore)"
              + " manifests and folded \(Folder.contentRootRebuildCount.value - rootsBefore) roots"
              + " in \(String(format: "%.4f", seconds))s")
    }

    // MARK: - The sequence a push runs

    /// The same sequence `FilePlugin.handlePush` runs per file.
    private func push(_ relativePath: String, contents: String) throws {
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(
                Path(relativePath).deletingLastComponent ?? .empty, pinned: true)
        let fullPath = Path(Folder.inputFileSystemName) / Path(relativePath)
        let (node, _) = try GraphSpecNode.parse("StaticFile(path: '\(fullPath.string)')").findOrCreateMatchingNode()
        let file = try XCTUnwrap(node.nodeAsAny() as? StaticFile)
        _ = try file.replaceContent(try contents.intern())
    }

    /// What `rm <folder>/*` does, followed by the collector, so the folder is left as empty
    /// as it was before anything was pushed into it.
    private func removeEverythingUnder(_ folder: String) throws {
        let root    = try engine.inputFileSystem
        let matcher = FileWildcardMatcher(input: InternalFileSystemLister(folder: root))

        for match in try matcher.findAllMatching(pathOrWildcard: Path("\(folder)/*")) {
            let child     = try XCTUnwrap(try root.childNode(path: match.path))
            let deletable = try XCTUnwrap(try child.nodeAsAny() as? UserDeletable)
            try deletable.deleteInInputFileSystem()
        }
        while try engine.processPendingDeletions() > 0 {
        }
        try Folder.flushDirtyManifests()
    }

    // MARK: - Reading the graph back

    /// The folder's Merkle root: the hash on its `contentRoot` port.
    private func root(of folderPath: String) throws -> DataObjectHash {
        let folder = try XCTUnwrap(try engine.inputFileSystem.childNode(path: folderPath))
        return try folder.readFromOutputPort(Folder.contentRootOutputPort).expectValue()
    }

    /// The bytes the root is the hash of.
    private func document(of folderPath: String) throws -> String {
        try root(of: folderPath).resolveAsString()
    }

    private func projectFinderIsScheduled() throws -> Bool {
        try engine.database.node.select(nodeID: try engine.projectFinder.requireID()).scheduled
    }

    private func manifestHash(of folderPath: String) throws -> DataObjectHash {
        let folder = try XCTUnwrap(try engine.inputFileSystem.childNode(path: folderPath))
        return try folder.readFromOutputPort(Folder.folderManifestOutputPort).expectValue()
    }
}
