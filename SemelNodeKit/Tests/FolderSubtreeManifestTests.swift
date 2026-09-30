//
//  FolderSubtreeManifestTests.swift
//  SemelNodeKit
//
//  B-135. Reading a folder's subtree manifest back as the manifests of the folders below
//  it: the shape a walk over manifests gathered a pass per level.
//

@testable import SemelNodeKit
import XCTest

final class FolderSubtreeManifestTests: XCTestCase {

    private var userStore: DataObjectStore!

    /// A store of this test's own: every subfolder's document is interned, and the user's
    /// store is not the place for a test's bytes.
    override func setUpWithError() throws {
        try super.setUpWithError()
        userStore = DataObjectStore.shared
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-subtree-tests/\(UUID().uuidString)", isDirectory: true)
        DataObjectStore.shared = DataObjectStore(storeRoot: root)
        try TypeRegistry.register(types: [FolderManifest.self, FolderSubtreeManifest.self])
    }

    override func tearDown() {
        DataObjectStore.shared = userStore
        super.tearDown()
    }

    private func file(_ name: String) -> FolderManifestEntry { .init(name: name, isFolder: false, isPinned: true) }

    private let listings: [String: [FolderManifestEntry]] = [
        "input:/lib":           [.init(name: "b.swift", isFolder: false, isPinned: true),
                                 .init(name: "a.swift", isFolder: false, isPinned: true),
                                 .init(name: "Views", isFolder: true, isPinned: true),
                                 .init(name: "Gone", isFolder: true, isPinned: false)],
        "input:/lib/Views":     [.init(name: "Rows", isFolder: true, isPinned: true)],
        "input:/lib/Views/Rows": [.init(name: "Row.swift", isFolder: false, isPinned: true)],
        "input:/lib/Gone":      [.init(name: "old.swift", isFolder: false, isPinned: false)],
    ]

    /// Every pinned folder at every depth, keyed by full path, each with its own listing;
    /// a ghost folder is named where it is and not descended into.
    func test_readsBackEveryPinnedFolderBelowWithItsListing() throws {
        let tree = try FolderSubtreeManifest.folding(at: "input:/lib", listings: listings)

        let manifests = try tree.folderManifests(at: "input:/lib")

        XCTAssertEqual(manifests.keys.sorted(), ["input:/lib", "input:/lib/Views", "input:/lib/Views/Rows"])
        XCTAssertEqual(manifests["input:/lib/Views/Rows"]?.entries.map(\.name), ["Row.swift"])
        XCTAssertEqual(manifests["input:/lib/Views/Rows"]?.baseFolderPath, "input:/lib/Views/Rows")
        XCTAssertEqual(manifests["input:/lib"]?.entries.map(\.name), ["Gone", "Views", "a.swift", "b.swift"],
                       "sorted by name, as UTF-8 bytes, whatever order the children were read in")
        XCTAssertEqual(manifests["input:/lib"]?.entries.first { $0.name == "Gone" }?.isPinned, false)
    }

    /// The tree is a value of its children: the same listings fold to one document, and a
    /// name changing anywhere below moves it.
    func test_aNameBelowMovesTheTreeAndTheSameNamesDoNot() throws {
        let tree = try FolderSubtreeManifest.folding(at: "input:/lib", listings: listings).toJSON()
        XCTAssertEqual(try FolderSubtreeManifest.folding(at: "input:/lib", listings: listings).toJSON(), tree)

        var renamed = listings
        renamed["input:/lib/Views/Rows"] = [file("Cell.swift")]
        XCTAssertNotEqual(try FolderSubtreeManifest.folding(at: "input:/lib", listings: renamed).toJSON(), tree)
    }

    /// A reader's stop rule is asked before it descends, and a declined folder's document
    /// is never read — nor a link's, when the reader places links rather than following.
    func test_aDeclinedFolderAndALinkNotFollowedAreNotRead() throws {
        let unreadable = String(repeating: "0", count: 64)
        let tree = FolderSubtreeManifest(entries: [
            FolderSubtreeEntry(name: "Assets.xcassets", isFolder: true, isPinned: true, subtree: unreadable),
            FolderSubtreeEntry(name: "Current", isFolder: true, isPinned: true, symbolicLinkTarget: "A", subtree: unreadable),
        ])

        let manifests = try tree.folderManifests(at: "input:/app", intoSymbolicLinks: false) { !$0.hasSuffix(".xcassets") }

        XCTAssertEqual(manifests.keys.sorted(), ["input:/app"])
        XCTAssertEqual(manifests["input:/app"]?.entries.first { $0.name == "Current" }?.symbolicLinkTarget, "A")
        XCTAssertThrowsError(try tree.folderManifests(at: "input:/app")) { error in
            XCTAssertEqual("\(error)", "the subtree manifest of input:/app/Assets.xcassets (\(unreadable)) cannot be read")
        }
    }
}
