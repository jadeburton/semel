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

    /// A subfolder that is a symbolic link is handed to a node building a tree to place
    /// where it stands, and no other subfolder is (B-77).
    func test_aFolderLinkIsHandedToTheNodeBuildingATree() {
        let manifest = FolderManifest(baseFolderPath: "input:/F/Versions",
                                      entries: [folder("A"), .init(name: "Current", isFolder: true, isPinned: true, symbolicLinkTarget: "A")])

        XCTAssertEqual(FolderTreeWalk.symbolicLinkFolders(of: [manifest]), ["input:/F/Versions/Current": "A"])
    }
}

extension Dictionary where Key == String, Value == GraphSpecNode {
    /// The trees as the spec text they render to, for assertions written against text.
    var rendered: [String: String] { mapValues { $0.asString(omitOutputPort: false) } }
}
