//
//  FolderRemovalScaleTests.swift
//  SemelCore
//

@testable import SemelCore
import SemelNodeKit
import XCTest

/// B-53. Removing the files of a folder costs the same handful of manifest rebuilds
/// whatever the folder holds: a rebuild per collected child, each O(children), is the
/// shape B-25 took out of `push`, and the collector walks into it from the other side.
///
/// The cost is asserted in rebuilds rather than in seconds, as `Folder.manifestRebuildCount`
/// is there for and `FolderManifestRebuildTests` does for a push: the defect is a count,
/// a count separates the two states by the size of the folder, and a stopwatch has to be
/// given a band wide enough to survive a loaded machine. Each test runs two sizes and
/// holds the count to a constant, which is what "grows linearly with the folder" means
/// when the per-file work is what is at issue.
final class FolderRemovalScaleTests: SemelCoreTestCase {

    /// The two folder sizes every growth test uses. Quadruple the files for a count that
    /// must not move; small enough that the whole file is about a second.
    private static let sizes = (small: 50, large: 200)

    /// Removing the files of one folder leaves one dirty mark behind however many files it
    /// walked, so the flush rebuilds that folder's manifest once. The allowance is for the
    /// folders above it, which a removal also touches — and it is far below the one rebuild
    /// per file that the count reaches when a deletion rebuilds as it goes.
    private static let rebuildAllowance = 3

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

    // MARK: - Growth

    /// `rm <folder>/*`: the files go and the folder stays, so every collected child reaches
    /// a parent that is still there. This is the removal that rebuilds per child.
    func test_removingTheContentsOfAFolderRebuildsItsManifestOnceNotPerFile() throws {
        let small = try removalOfAFolderOf(Self.sizes.small) { folder in "\(folder)/*" }
        let large = try removalOfAFolderOf(Self.sizes.large) { folder in "\(folder)/*" }

        XCTAssertLessThanOrEqual(small.rebuilds, Self.rebuildAllowance, small.described)
        XCTAssertEqual(large.rebuilds, small.rebuilds,
                       "the count must not follow the folder's size — \(large.described)")
    }

    /// `rm <folder>`: the folder goes with its files, and nothing under it is rebuilt on
    /// the way out. A pinned count, not a discriminating one: the folder deletes itself
    /// before its children are removed, so `onChildDeleted` is never reached on this path
    /// and a per-child rebuild could not show here; the test above is the one that catches
    /// that.
    func test_removingAWholeFolderRebuildsNoManifestPerFile() throws {
        let small = try removalOfAFolderOf(Self.sizes.small) { folder in folder }
        let large = try removalOfAFolderOf(Self.sizes.large) { folder in folder }

        XCTAssertLessThanOrEqual(small.rebuilds, Self.rebuildAllowance, small.described)
        XCTAssertEqual(large.rebuilds, small.rebuilds,
                       "the count must not follow the folder's size — \(large.described)")
    }

    // MARK: - What is left behind

    func test_theFolderNodeIsGoneOnceTheCollectorHasRun() throws {
        try pushFiles(50, into: "tree")

        try remove(pattern: "tree")
        try collect()
        try Folder.flushDirtyManifests()

        XCTAssertNil(try engine.inputFileSystem.childNode(path: "tree"), "the folder itself")
        XCTAssertNil(try engine.inputFileSystem.childNode(path: "tree/file0.c"), "and its files")
        XCTAssertFalse(try rootManifestNames().contains("tree"), "and the root no longer lists it")
    }

    /// The files of `rm <folder>/*` leave the folder behind, empty: the user asked for the
    /// files, and the folder is still pinned.
    func test_removingTheContentsLeavesAnEmptyFolderAndAnEmptyManifest() throws {
        try pushFiles(50, into: "tree")

        try remove(pattern: "tree/*")
        try collect()
        try Folder.flushDirtyManifests()

        XCTAssertNotNil(try engine.inputFileSystem.childNode(path: "tree"))
        XCTAssertEqual(try manifest(of: "tree").entries.count, 0)
    }

    // MARK: - Draining once

    /// `rm` takes a batch the way `push` does (B-53). Inside one, the marks a removal
    /// leaves ask for a single pass however many files it walks; without one the engine is
    /// signalled per file and drains against a tree the walk is still taking apart.
    func test_aRemovalInsideABatchAsksForOnePass() throws {
        try pushFiles(50, into: "batched")
        try pushFiles(50, into: "loose")

        let beforeBatch = engine.loopSignalsSent
        engine.beginBatch()
        try remove(pattern: "batched/*")
        try collect()
        engine.endBatch()
        let inABatch = engine.loopSignalsSent - beforeBatch

        let beforeLoose = engine.loopSignalsSent
        try remove(pattern: "loose/*")
        try collect()
        let loose = engine.loopSignalsSent - beforeLoose

        XCTAssertEqual(inABatch, 1, "the whole removal asks for one pass")
        XCTAssertGreaterThan(loose, 1, "and without the batch, one per file")
    }

    // MARK: - The sequence a push and an rm run

    /// The same sequence `FilePlugin.handlePush` runs per file.
    private func push(_ relativePath: String, contents: String) throws {
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(
                Path(relativePath).deletingLastComponent ?? .empty, pinned: true)
        let fullPath = Path(Folder.inputFileSystemName) / Path(relativePath)
        let (node, _) = try GraphSpecNode.parse("StaticFile(path: '\(fullPath.string)')").findOrCreateMatchingNode()
        let file = try XCTUnwrap(node.nodeAsAny() as? StaticFile)
        _ = try file.replaceContent(try contents.intern())
    }

    private func pushFiles(_ count: Int, into folder: String) throws {
        for index in 0..<count {
            try push("\(folder)/file\(index).c", contents: "int f\(index)(void) { return \(index); }")
        }
    }

    /// What `RequestHandler.remove(pattern:)` does: match, then delete every match.
    private func remove(pattern: String) throws {
        let root    = try engine.inputFileSystem
        let matcher = FileWildcardMatcher(input: InternalFileSystemLister(folder: root))

        for match in try matcher.findAllMatching(pathOrWildcard: Path(pattern)) {
            let child     = try XCTUnwrap(try root.childNode(path: match.path))
            let deletable = try XCTUnwrap(try child.nodeAsAny() as? UserDeletable)
            try deletable.deleteInInputFileSystem()
        }
    }

    /// The idle-time collector, run to a fixed point the way the engine runs it.
    private func collect() throws {
        while try engine.processPendingDeletions() > 0 {
        }
    }

    /// What one removal cost: the manifests rebuilt by it, and the seconds it took, which
    /// are carried for a failure message to quote and are never asserted on.
    private struct RemovalCost {
        let files:    Int
        let rebuilds: Int
        let seconds:  TimeInterval

        var described: String {
            "\(files) files: \(rebuilds) rebuilds in \(String(format: "%.3f", seconds))s"
        }
    }

    /// Pushes `count` files into a folder of their own, reads the manifest so the folder
    /// starts clean, then removes what `pattern` names and collects. The push is set-up and
    /// is outside everything the cost counts.
    private func removalOfAFolderOf(_ count: Int, pattern: (String) -> String) throws -> RemovalCost {
        let folder = "tree\(count)"
        try pushFiles(count, into: folder)
        _ = try manifest(of: folder)

        let rebuiltBefore = Folder.manifestRebuildCount.value
        let start = Date.now
        try remove(pattern: pattern(folder))
        try collect()
        try Folder.flushDirtyManifests()

        return RemovalCost(files: count,
                           rebuilds: Folder.manifestRebuildCount.value - rebuiltBefore,
                           seconds: Date.now.timeIntervalSince(start))
    }

    // MARK: - Reading the graph back

    private func manifest(of folderPath: String) throws -> FolderManifest {
        let folder = try XCTUnwrap(try engine.inputFileSystem.childNode(path: folderPath))
        let json = try folder.readFromOutputPort(Folder.folderManifestOutputPort).expectValue().resolveAsString()
        return try XCTUnwrap(try TypeRegistry.decode(encodedJSON: json) as? FolderManifest)
    }

    private func rootManifestNames() throws -> [String] {
        try manifest(of: "").entries.map(\.name)
    }
}
