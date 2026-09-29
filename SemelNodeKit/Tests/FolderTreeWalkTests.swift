//
//  FolderTreeWalkTests.swift
//  semel_tests
//

@testable import SemelNodeKit
import XCTest

final class FolderTreeWalkTests: XCTestCase {

    // XCTestCase rather than the engine's SemelCoreTestCase: the walk is a pure function
    // over manifests with no process-globals to isolate, and SemelNodeKit deliberately
    // cannot see the engine's test helpers.

    private func file(_ name: String) -> FolderManifestEntry { .init(name: name, isFolder: false, isPinned: true) }
    private func folder(_ name: String) -> FolderManifestEntry { .init(name: name, isFolder: true, isPinned: true) }

    /// `include` narrows `fileSpecs` to the caller's scope — a target's `SourceScope` or
    /// an asset catalog's own filter — without changing the unfiltered signature's
    /// callers, who see the default that accepts everything.
    func test_fileSpecsRestrictsToTheFilesIncludeAccepts() {
        let manifest = FolderManifest(baseFolderPath: "input:/pkg/Sources",
                                      entries: [file("Keep.swift"), file("Drop.txt")])

        let specs = FolderTreeWalk.fileSpecs(of: [manifest]) { $0.hasSuffix(".swift") }

        XCTAssertEqual(specs.rendered, ["input:/pkg/Sources/Keep.swift": "StaticFile(path: 'input:/pkg/Sources/Keep.swift').output"])
    }

    /// The default keeps every pinned file, unchanged from before `include` existed.
    func test_fileSpecsWithNoIncludeKeepsEveryPinnedFile() {
        let manifest = FolderManifest(baseFolderPath: "input:/pkg/Sources",
                                      entries: [file("One.swift"), file("Two.txt")])

        let specs = FolderTreeWalk.fileSpecs(of: [manifest])

        XCTAssertEqual(Set(specs.keys), ["input:/pkg/Sources/One.swift", "input:/pkg/Sources/Two.txt"])
    }

    /// The same narrowing for subfolders: a caller can stop the walk from descending into
    /// a subfolder it already knows is out of scope.
    func test_subfolderSpecsRestrictsToTheFoldersIncludeAccepts() {
        let manifest = FolderManifest(baseFolderPath: "input:/pkg",
                                      entries: [folder("Core"), folder("Vendor")])

        let specs = FolderTreeWalk.subfolderSpecs(of: [manifest]) { $0 != "input:/pkg/Vendor" }

        XCTAssertEqual(specs.rendered, ["input:/pkg/Core": "Folder(path: 'input:/pkg/Core').manifest"])
    }

    /// From the root down, as far as the manifests that have arrived reach: a subfolder
    /// whose manifest is still on its way is where the walk stops, and a manifest the root
    /// no longer reaches is not walked however long it stays on its wire.
    func test_subfolderSpecsBelowARootWalksAsFarAsTheArrivedManifestsReach() {
        let arrived = [
            "input:/src":           FolderManifest(baseFolderPath: "input:/src", entries: [file("a.c"), folder("lib")]),
            "input:/src/lib":       FolderManifest(baseFolderPath: "input:/src/lib", entries: [folder("deep"), folder("skip")]),
            "input:/src/gone":      FolderManifest(baseFolderPath: "input:/src/gone", entries: [folder("stale")]),
        ]

        let specs = FolderTreeWalk.subfolderSpecs(below: "input:/src", arrived: arrived) { !$0.hasSuffix("/skip") }

        XCTAssertEqual(specs.keys.sorted(), ["input:/src/lib", "input:/src/lib/deep"])
    }

    /// Nothing below a root whose own manifest has not arrived.
    func test_subfolderSpecsBelowARootThatHasNotArrivedIsEmpty() {
        XCTAssertTrue(FolderTreeWalk.subfolderSpecs(below: "input:/src", arrived: [:]).isEmpty)
    }

    /// A subfolder that is a symbolic link holds what it names, and a walk reading files
    /// descends into it; a walk building a tree does not, and is handed the link to place
    /// (B-77).
    func test_aWalkBuildingATreeDoesNotDescendIntoAFolderLink() {
        let manifest = FolderManifest(baseFolderPath: "input:/F/Versions",
                                      entries: [folder("A"), .init(name: "Current", isFolder: true, isPinned: true, symbolicLinkTarget: "A")])

        XCTAssertEqual(FolderTreeWalk.subfolderSpecs(of: [manifest]).keys.sorted(),
                       ["input:/F/Versions/A", "input:/F/Versions/Current"])
        XCTAssertEqual(FolderTreeWalk.subfolderSpecs(of: [manifest], intoSymbolicLinks: false).keys.sorted(),
                       ["input:/F/Versions/A"])
        XCTAssertEqual(FolderTreeWalk.symbolicLinkFolders(of: [manifest]), ["input:/F/Versions/Current": "A"])
    }
}

extension Dictionary where Key == String, Value == GraphSpecNode {
    /// The trees as the spec text they render to, for assertions written against text.
    var rendered: [String: String] { mapValues { $0.asString(omitOutputPort: false) } }
}
