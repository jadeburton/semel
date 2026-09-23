//
//  FolderRemovalScaleTests.swift
//  SemelCore
//

@testable import SemelCore
import SemelNodeKit
import XCTest

/// B-53. Removing a folder of a few thousand files costs what removing one of a few
/// hundred costs times the ratio of the two sizes, not times its square. The cost sits in
/// the parent's manifest: a rebuild per collected child, each O(children), is the shape
/// B-25 took out of `push`, and the collector walks into it from the other side.
///
/// Both tests time the removal and the collection, never the push that set them up, and
/// compare 3000 files against 1000. Linear is a ratio near 3 and quadratic near 9; the
/// bound sits between them, far enough from 3 that a loaded machine does not trip it.
final class FolderRemovalScaleTests: SemelCoreTestCase {

    /// 3000 against 1000 files. Linear work lands near 3.
    private static let growthBound = 5.0

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

    /// `rm <folder>`: the folder goes with its files.
    func test_removingAWholeFolderGrowsLinearlyWithItsSize() throws {
        let small = try timeRemoving(1000) { folder in folder }
        let large = try timeRemoving(3000) { folder in folder }

        XCTAssertLessThan(large / small, Self.growthBound,
                          "1000 files: \(small)s, 3000 files: \(large)s")
    }

    /// `rm <folder>/*`: the files go and the folder stays, so every collected child
    /// reaches a parent that is still there — the manifest rebuild per child.
    func test_removingTheContentsOfAFolderGrowsLinearlyWithItsSize() throws {
        let small = try timeRemoving(1000) { folder in "\(folder)/*" }
        let large = try timeRemoving(3000) { folder in "\(folder)/*" }

        XCTAssertLessThan(large / small, Self.growthBound,
                          "1000 files: \(small)s, 3000 files: \(large)s")
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

    /// Pushes `count` files into a folder of their own, removes what `pattern` names and
    /// collects, and returns how long the removal and the collection took together.
    private func timeRemoving(_ count: Int, pattern: (String) -> String) throws -> TimeInterval {
        let folder = "tree\(count)"
        try pushFiles(count, into: folder)

        let start = Date.now
        try remove(pattern: pattern(folder))
        try collect()
        try Folder.flushDirtyManifests()
        return Date.now.timeIntervalSince(start)
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
