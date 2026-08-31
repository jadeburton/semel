//
//  PinnedPathCreationTests.swift
//  SemelCoreTests
//
//  ensureEntirePathExistsAsFolders(pinned:) is how every pushed file gets its folders, so
//  it runs constantly and its parents' manifests have to be right afterwards.
//
//  A newly pinned folder is announced to its parent exactly once, through setPinned's
//  onChildContentChanged. Folder answers that and onChildAdded identically, with
//  refreshOutputs, so announcing it a second way would rebuild the manifest for nothing —
//  and one notification carrying both facts is a thinner thread than two. These check it
//  holds.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class PinnedPathCreationTests: SemelCoreTestCase {

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

    private func folder(_ relativePath: String) throws -> Folder {
        let node = try XCTUnwrap(engine.inputFileSystem.childNode(path: Path(relativePath)))
        return try XCTUnwrap(node.nodeAsAny() as? Folder)
    }

    /// What a parent publishes about its children. Read back from the output port rather
    /// than recomputed, because the port is what downstream nodes actually see — and the
    /// removed notification was the only other thing that wrote it.
    private func publishedManifest(of folder: Folder) throws -> FolderManifest {
        let value = try folder.thisNode.readFromOutputPort(Folder.folderManifestOutputPort)
        let json = try value.expectValue().resolveAsString()
        return try XCTUnwrap(TypeRegistry.decode(encodedJSON: json) as? FolderManifest)
    }

    private func entry(_ name: String, in manifest: FolderManifest) throws -> FolderManifestEntry {
        try XCTUnwrap(manifest.entries.first { $0.name == name },
                      "no '\(name)' in \(manifest.entries.map(\.name))")
    }

    /// Every folder on a freshly created path is pinned, and every parent says so. One
    /// notification has to carry both facts — that the child appeared, and that it is pinned.
    func test_everyFolderOnANewPinnedPathIsPublishedAsPinned() throws {
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(Path("a/b/c"), pinned: true)

        for (parent, child) in [("a", "b"), ("a/b", "c")] {
            let published = try entry(child, in: try publishedManifest(of: try folder(parent)))
            XCTAssertTrue(published.isFolder, "\(parent)/\(child) should be a folder")
            XCTAssertTrue(published.isPinned, "\(parent)/\(child) should be published as pinned")
        }

        let root = try entry("a", in: try publishedManifest(of: XCTUnwrap(
            engine.inputFileSystem.nodeAsAny() as? Folder)))
        XCTAssertTrue(root.isPinned)
    }

    /// The interesting half: the folder already exists and only its pinned state changes.
    /// Here there is no "child added" event at all — the parent learns about it solely
    /// through the notification setPinned sends.
    func test_pinningAnAlreadyExistingFolderUpdatesItsParent() throws {
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(Path("later"), pinned: false)
        XCTAssertFalse(try entry("later", in: try publishedManifest(of: XCTUnwrap(
            engine.inputFileSystem.nodeAsAny() as? Folder))).isPinned,
            "fixture: starts unpinned")

        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(Path("later"), pinned: true)

        XCTAssertTrue(try entry("later", in: try publishedManifest(of: XCTUnwrap(
            engine.inputFileSystem.nodeAsAny() as? Folder))).isPinned,
            "the parent must see the pin without a second notification")
    }

    /// Deeper: pinning a nested path where the outer folders already exist unpinned. Each
    /// level has to be republished, not just the last.
    func test_pinningANestedPathUpdatesEveryLevel() throws {
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(Path("x/y/z"), pinned: false)
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(Path("x/y/z"), pinned: true)

        for (parent, child) in [("x", "y"), ("x/y", "z")] {
            XCTAssertTrue(try entry(child, in: try publishedManifest(of: try folder(parent))).isPinned,
                          "\(parent)/\(child) should be published as pinned")
        }
    }

    /// Pinning is idempotent — the guard skips a folder that is already pinned, so a repeat
    /// push must not disturb what the parent publishes.
    func test_repeatingAPinChangesNothing() throws {
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(Path("stable/inner"), pinned: true)
        let before = try publishedManifest(of: try folder("stable")).entries.map { "\($0.name):\($0.isPinned)" }

        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(Path("stable/inner"), pinned: true)
        let after = try publishedManifest(of: try folder("stable")).entries.map { "\($0.name):\($0.isPinned)" }

        XCTAssertEqual(before, after)
    }
}
