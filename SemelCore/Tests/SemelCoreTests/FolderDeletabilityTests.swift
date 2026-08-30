//
//  FolderDeletabilityTests.swift
//  SemelCoreTests
//
//  Folder.canBeDeleted decides whether the collector may take a folder and everything under
//  it, so a wrong answer here is data loss rather than a slow build: say yes about a folder
//  holding a pushed file and the file goes.
//
//  It reads pinned state directly from child output ports, one query per kind, the way
//  buildManifest does — which is fast but loses the polymorphism it used to get from asking
//  each child through its own canBeDeleted. These cases pin the behaviour that mapping has
//  to preserve, and the last one checks the two readings still agree on a mixed tree.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class FolderDeletabilityTests: SemelCoreTestCase {

    private var engine: BuildEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    private var database: DatabaseLayer { engine.database }

    // MARK: - Building trees

    /// `pinFolders` matters: a folder the user made is pinned and blocks its own deletion
    /// whatever is inside it, so a test about a *child* blocking the parent has to put the
    /// child under an unpinned folder or it proves nothing.
    @discardableResult
    private func pushFile(_ relativePath: String,
                          contents: String? = "int main(){}",
                          pinFolders: Bool = true) throws -> StaticFile {
        let fullPath = Path(Folder.inputFileSystemName) / Path(relativePath)
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(
                Path(relativePath).deletingLastComponent ?? .empty, pinned: pinFolders)

        let shape = try GraphShapeNode.parse("StaticFile(path: '\(fullPath.string)')")
        let (node, _) = try shape.findOrCreateMatchingNode()
        let file = try XCTUnwrap(node.nodeAsAny() as? StaticFile)

        if let contents {
            _ = try file.replaceContent(try contents.intern())
        }
        return file
    }

    private func folder(_ relativePath: String) throws -> Folder {
        let node = try XCTUnwrap(engine.inputFileSystem.childNode(path: Path(relativePath)))
        return try XCTUnwrap(node.nodeAsAny() as? Folder)
    }

    /// The reading this replaced: ask every child, polymorphically, through its own
    /// `canBeDeleted`. Lives here rather than in the engine so the fast path has something
    /// independent to be checked against.
    private func canBeDeletedPolymorphically(_ folder: Folder) throws -> Bool {
        let childrenOK = try folder.thisNode.allChildren
            .filter { try !$0.nodeFunction().canBeDeleted() }
            .isEmpty
        return try childrenOK && !(folder.canBePinned() && folder.isPinned)
    }

    // MARK: - What blocks a delete

    /// A pushed file is held by the user, not by the graph. Collecting the folder around it
    /// would take the file with it.
    func test_aFolderHoldingAPushedFileCannotBeDeleted() throws {
        try pushFile("src/main.c", pinFolders: false)

        XCTAssertFalse(try folder("src").canBeDeleted(),
                       "the folder itself is unpinned, so the file is the only thing saying no")
    }

    /// A ghost — referenced but never pushed, or pushed and then removed — holds nothing.
    func test_aFolderHoldingOnlyAGhostCanBeDeleted() throws {
        try pushFile("ghosts/never.c", contents: nil, pinFolders: false)

        XCTAssertTrue(try folder("ghosts").canBeDeleted())
    }

    /// Recursion: the blocking file is two levels down, so a check that only looked at
    /// immediate children would wrongly say yes.
    func test_aPushedFileBlocksEveryFolderAboveIt() throws {
        // Unpinned folders throughout, so the only thing that can block is the file.
        try pushFile("a/b/c/deep.c", pinFolders: false)

        XCTAssertFalse(try folder("a").canBeDeleted())
        XCTAssertFalse(try folder("a/b").canBeDeleted())
        XCTAssertFalse(try folder("a/b/c").canBeDeleted())
    }

    /// The folder's own pinned state, independent of its children. Checked before the
    /// children now, since it is one read and settles the question on its own.
    func test_aPinnedFolderCannotBeDeletedEvenWhenEmpty() throws {
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(Path("pinned"), pinned: true)

        XCTAssertFalse(try folder("pinned").canBeDeleted())
    }

    func test_anUnpinnedEmptyFolderCanBeDeleted() throws {
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(Path("transient"), pinned: false)

        XCTAssertTrue(try folder("transient").canBeDeleted())
    }

    /// A subfolder that is itself pinned blocks its parent, even with nothing in it — the
    /// kind→port mapping has to read a Folder's pinned state from a different port than a
    /// StaticFile's, and swapping them would lose exactly this.
    func test_aPinnedSubfolderBlocksItsParent() throws {
        // Pinning a path pins every folder on it, so `outer` has to be unpinned again for
        // this to be about `inner` rather than about `outer` itself.
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(Path("outer/inner"), pinned: true)
        try folder("outer").setPinned(false)

        XCTAssertFalse(try folder("outer").isPinned, "fixture: outer must be unpinned")
        XCTAssertFalse(try folder("outer").canBeDeleted())
    }

    // MARK: - Agreement

    /// One tree with every case in it at once, checked against the polymorphic reading. This
    /// is the guard that the hardcoded kind→port mapping still means what asking each child
    /// meant — the same guarantee `test_manifestPinnedStateAgreesWithEachChildsOwn` gives
    /// the manifest.
    func test_theFastReadingAgreesWithAskingEachChild() throws {
        // A pinned file, a ghost, a pinned subfolder, an unpinned one, and a nested keeper —
        // every combination the kind-to-port mapping has to tell apart, in one tree.
        try pushFile("mixed/kept.c", pinFolders: false)
        try pushFile("mixed/ghost.c", contents: nil, pinFolders: false)
        try pushFile("mixed/nested/kept.c", pinFolders: false)
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(Path("mixed/pinnedSub"), pinned: true)
        try folder("mixed").setPinned(false)

        try pushFile("collectable/ghost.c", contents: nil, pinFolders: false)
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(Path("collectable/empty"), pinned: false)

        // Both answers appear below, so agreement is not agreement on a constant.
        XCTAssertFalse(try folder("mixed").canBeDeleted())
        XCTAssertTrue(try folder("collectable").canBeDeleted())

        for path in ["mixed", "mixed/nested", "mixed/pinnedSub",
                     "collectable", "collectable/empty"] {
            let subject = try folder(path)
            XCTAssertEqual(try subject.canBeDeleted(),
                           try canBeDeletedPolymorphically(subject),
                           "disagreement at \(path)")
        }
    }
}
