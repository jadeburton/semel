//
//  FolderSubtreeManifestTests.swift
//  SemelCore
//

@testable import SemelCore
import SemelNodeKit
import XCTest

/// B-135. A folder's `subtreeManifest` port carries the names below it at every depth, each
/// subfolder's own by hash, so a consumer that has to know a whole tree asks once and has it
/// on the next pass. Asserted here: that the tree reads back as every folder's listing; that
/// it is kept the way the content root is — a change of names refolds one subtree manifest
/// per ancestor, never one per folder, counted in folds — and that it holds names and no
/// content, so an edit moves none of it and wakes nothing wired to it.
final class FolderSubtreeManifestTests: SemelCoreTestCase {

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

    // MARK: - What it holds

    /// Every folder below, at every depth, reads back as the listing its own manifest
    /// gives: the tree is the walk a consumer did a pass per level, in one value.
    func test_aFoldersTreeReadsBackAsEveryListingBelowIt() throws {
        try push("pkg/Sources/Lib/Lib.swift", contents: "struct Lib {}")
        try push("pkg/Sources/Lib/Resources/en.lproj/Localizable.strings", contents: "\"a\" = \"b\";")
        try push("pkg/Package.swift", contents: "// swift-tools-version:5.9")
        try Folder.flushDirtyManifests()

        let manifests = try tree(of: "pkg").folderManifests(at: "input:/pkg")

        XCTAssertEqual(manifests.keys.sorted(), ["input:/pkg", "input:/pkg/Sources", "input:/pkg/Sources/Lib",
                                                 "input:/pkg/Sources/Lib/Resources", "input:/pkg/Sources/Lib/Resources/en.lproj"])
        for (path, listing) in manifests {
            let own = try manifest(of: String(path.dropFirst("input:/".count)))
            XCTAssertEqual(listing.entries.map(\.name).sorted(), own.entries.map(\.name).sorted(), path)
            XCTAssertEqual(listing.baseFolderPath, path)
        }
    }

    /// What a reader does not descend into it never reads: the stop rule is the reader's,
    /// and the documents below a folder it declines are not fetched.
    func test_aReaderThatDeclinesAFolderReadsNothingBelowIt() throws {
        try push("app/Assets.xcassets/Icon.imageset/Contents.json", contents: "{}")
        try push("app/Views/Row.swift", contents: "struct Row {}")
        try Folder.flushDirtyManifests()

        let manifests = try tree(of: "app").folderManifests(at: "input:/app") { !$0.hasSuffix(".xcassets") }

        XCTAssertEqual(manifests.keys.sorted(), ["input:/app", "input:/app/Views"])
        XCTAssertEqual(manifests["input:/app"]?.entries.map(\.name).sorted(), ["Assets.xcassets", "Views"],
                       "the declined folder is still named where it is")
    }

    /// A file taken out is a ghost until the collector takes it: the tree says so by its
    /// pinned state, as the manifest does, and moves.
    func test_aRemovedFileIsAGhostInTheTreeAndMovesIt() throws {
        try push("gone/mid/drop.c", contents: "int drop;")
        try Folder.flushDirtyManifests()
        let before = try treeHash(of: "gone")

        let node = try XCTUnwrap(try engine.inputFileSystem.childNode(path: "gone/mid/drop.c"))
        try XCTUnwrap(node.nodeAsAny() as? StaticFile).deleteInInputFileSystem()
        try Folder.flushDirtyManifests()

        XCTAssertNotEqual(try treeHash(of: "gone"), before, "a pinned state below changed")
        let entry = try XCTUnwrap(try tree(of: "gone").folderManifests(at: "input:/gone")["input:/gone/mid"]?
                                    .entries.first { $0.name == "drop.c" })
        XCTAssertFalse(entry.isPinned)
    }

    /// The document is the names, not where they are: the same tree at two paths is one
    /// value, as its content root is one hash.
    func test_theSameTreeAtTwoPathsHasOneSubtreeManifest() throws {
        for folder in ["left", "right/nested"] {
            try push("\(folder)/src/a.c", contents: "int a;")
            try push("\(folder)/include/a.h", contents: "int a;")
        }
        try Folder.flushDirtyManifests()

        XCTAssertEqual(try treeHash(of: "left"), try treeHash(of: "right/nested"))
    }

    // MARK: - Names, and no content

    /// An edit changes no name, so it moves no subtree manifest — not the holding folder's,
    /// not an ancestor's — and the refold it costs is the holding folder's alone: the one
    /// that finds nothing moved marks nothing above it.
    func test_anEditRefoldsTheHoldingFolderAloneAndMovesNoTree() throws {
        try push("stable/mid/leaf/f.c", contents: "int f;")
        try Folder.flushDirtyManifests()
        let before = try ["", "stable", "stable/mid", "stable/mid/leaf"].map { try treeHash(of: $0) }

        let foldsBefore = Folder.subtreeManifestRebuildCount.value
        try push("stable/mid/leaf/f.c", contents: "int f = 1;")
        try Folder.flushDirtyManifests()

        XCTAssertEqual(Folder.subtreeManifestRebuildCount.value - foldsBefore, 1)
        XCTAssertEqual(try ["", "stable", "stable/mid", "stable/mid/leaf"].map { try treeHash(of: $0) }, before)
    }

    /// A new name three folders down refolds one subtree manifest per folder on the path
    /// to the root and no other — the depth of the tree, not its size — and moves each.
    func test_aNewNameDeepDownRefoldsOneSubtreeManifestPerAncestor() throws {
        for index in 0..<40 {
            try push("wide/sibling\(index)/f.c", contents: "\(index)")
        }
        try push("wide/deep/mid/leaf/f.c", contents: "start")
        try Folder.flushDirtyManifests()
        let before = try treeHash(of: "")

        let foldsBefore = Folder.subtreeManifestRebuildCount.value
        try push("wide/deep/mid/leaf/g.c", contents: "new")
        try Folder.flushDirtyManifests()
        let folds = Folder.subtreeManifestRebuildCount.value - foldsBefore

        // input: / wide / deep / mid / leaf — five folders on the path, and nothing else.
        XCTAssertEqual(folds, 5, "folded \(folds) subtree manifests for one new name in a tree of 45 folders")
        XCTAssertNotEqual(try treeHash(of: ""), before, "the name reached the top")
    }

    /// Pushing many files into one folder folds its subtree manifest once, not once per
    /// file — the deferral B-25 gave the manifest — and each ancestor once.
    func test_pushingManyFilesFoldsEachSubtreeManifestOnce() throws {
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(Path("bulk/files"), pinned: true)
        try Folder.flushDirtyManifests()

        let foldsBefore = Folder.subtreeManifestRebuildCount.value
        for index in 0..<200 {
            try push("bulk/files/f\(index).c", contents: "int f\(index);")
        }
        try Folder.flushDirtyManifests()

        XCTAssertEqual(Folder.subtreeManifestRebuildCount.value - foldsBefore, 3, "input:, bulk and bulk/files, once each")
        XCTAssertEqual(try tree(of: "bulk").folderManifests(at: "input:/bulk")["input:/bulk/files"]?.entries.count, 200)
    }

    /// What the tree's standing still is worth, said in the terms that cost time: the node
    /// wired to `input:`'s tree — the project finder — is not woken by an edit three folders
    /// down, and is woken by a new name there.
    func test_aConsumerOfTheRootsTreeWakesForANewNameAndNotForAnEdit() throws {
        try engine.projectFinder.makeNode().processWithPreCheck()
        try push("pkg/Sources/Lib/main.swift", contents: "print(1)")
        try Folder.flushDirtyManifests()
        try engine.projectFinder.setScheduled(false)

        try push("pkg/Sources/Lib/main.swift", contents: "print(2)")
        try Folder.flushDirtyManifests()
        XCTAssertFalse(try projectFinderIsScheduled(), "an edit is not a change of names")

        try push("pkg/Sources/Lib/second.swift", contents: "print(3)")
        try Folder.flushDirtyManifests()
        XCTAssertTrue(try projectFinderIsScheduled(), "a name appeared three folders below the root it reads")
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

    // MARK: - Reading the graph back

    private func folderNode(_ folderPath: String) throws -> NodeRecord {
        folderPath.isEmpty ? try engine.inputFileSystem : try XCTUnwrap(try engine.inputFileSystem.childNode(path: folderPath))
    }

    private func treeHash(of folderPath: String) throws -> DataObjectHash {
        try folderNode(folderPath).readFromOutputPort(Folder.subtreeManifestOutputPort).expectValue()
    }

    private func tree(of folderPath: String) throws -> FolderSubtreeManifest {
        try TypeRegistry.decodeAndCast(encodedJSON: try treeHash(of: folderPath).resolveAsString())
    }

    private func manifest(of folderPath: String) throws -> FolderManifest {
        let json = try folderNode(folderPath).readFromOutputPort(Folder.folderManifestOutputPort).expectValue().resolveAsString()
        return try TypeRegistry.decodeAndCast(encodedJSON: json)
    }

    private func projectFinderIsScheduled() throws -> Bool {
        try engine.database.node.select(nodeID: try engine.projectFinder.requireID()).scheduled
    }
}
