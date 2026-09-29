//
//  TreeManifestTests.swift
//  SemelNodeKitTests
//
//  A tree's symbolic links (B-77): how an entry is spelled, how a path is followed through
//  links, how a builder's files become a tree holding only links that resolve inside it,
//  and how trees merge.
//

@testable import SemelNodeKit
import XCTest

final class TreeManifestTests: XCTestCase {

    // MARK: - Encoding

    /// A file is spelled as every tree spelled one before links, so a tree without links
    /// interns to the hash it always did; a link is its path and its target, and nothing
    /// else. Keys sorted, as `TypeRegistry` writes every value.
    func test_aFileAndALinkAreSpelledOut() throws {
        let tree = TreeManifest(entries: [TreeManifestEntry(path: "Tiny.framework/Tiny", symbolicLinkTarget: "Versions/Current/Tiny"),
                                          TreeManifestEntry(path: "Tiny.framework/Versions/A/Tiny", hash: "abc", mode: 0o755)])

        try TypeRegistry.register(types: [TreeManifest.self])
        let json = try tree.toJSON()

        XCTAssertTrue(json.contains(#"{"path":"Tiny.framework\/Tiny","symbolicLink":"Versions\/Current\/Tiny"}"#), json)
        XCTAssertTrue(json.contains(#"{"hash":"abc","mode":493,"path":"Tiny.framework\/Versions\/A\/Tiny"}"#), json)
        let decoded: TreeManifest = try TypeRegistry.decodeAndCast(encodedJSON: json)
        XCTAssertEqual(decoded, tree)
    }

    // MARK: - Following links

    private let framework = TreeManifest(entries: [
        TreeManifestEntry(path: "Tiny.framework/Versions/A/Tiny",           hash: "binary", mode: 0o755),
        TreeManifestEntry(path: "Tiny.framework/Versions/A/Headers/Tiny.h", hash: "header", mode: 0o644),
        TreeManifestEntry(path: "Tiny.framework/Versions/Current",          symbolicLinkTarget: "A"),
        TreeManifestEntry(path: "Tiny.framework/Tiny",                      symbolicLinkTarget: "Versions/Current/Tiny"),
        TreeManifestEntry(path: "Tiny.framework/Headers",                   symbolicLinkTarget: "Versions/Current/Headers"),
    ])

    /// Each link on the way is followed from the folder holding it, a chain of them too.
    func test_aPathIsFollowedThroughEveryLinkOnTheWay() {
        XCTAssertEqual(framework.resolve("Tiny.framework/Tiny"),
                       .file(TreeManifestEntry(path: "Tiny.framework/Versions/A/Tiny", hash: "binary", mode: 0o755)))
        XCTAssertEqual(framework.resolve("Tiny.framework/Headers/Tiny.h"),
                       .file(TreeManifestEntry(path: "Tiny.framework/Versions/A/Headers/Tiny.h", hash: "header", mode: 0o644)))
        XCTAssertEqual(framework.resolve("Tiny.framework/Versions/Current"), .folder)
        XCTAssertEqual(framework.resolve("Tiny.framework/Versions/Current/../A/Tiny"),
                       .file(TreeManifestEntry(path: "Tiny.framework/Versions/A/Tiny", hash: "binary", mode: 0o755)))
    }

    /// What names nothing here: a missing entry, a climb above the root, a path below a
    /// file, and a loop of links.
    func test_aPathNamingNothingHereResolvesToNothing() {
        let loop = TreeManifest(entries: [TreeManifestEntry(path: "a", symbolicLinkTarget: "b"),
                                          TreeManifestEntry(path: "b", symbolicLinkTarget: "a")])

        XCTAssertNil(framework.resolve("Tiny.framework/Missing"))
        XCTAssertNil(framework.resolve("../Tiny.framework/Tiny"))
        XCTAssertNil(framework.resolve("Tiny.framework/Tiny/below"))
        XCTAssertNil(loop.resolve("a"))
    }

    // MARK: - Placing what a builder read

    private func file(_ path: String, _ hash: String, link: String? = nil, mode: UInt16 = 0o644) -> TreeManifest.PlacedFile {
        .init(path: path, hash: hash, metadata: FileMetadata(mode: mode, symbolicLinkTarget: link))
    }

    /// A link whose target is placed too is a link; a folder link is a link where what it
    /// names is in the tree.
    func test_aLinkWhoseTargetIsInTheTreeIsALink() {
        let tree = TreeManifest(placing: [file("F/Versions/A/Tiny", "binary", mode: 0o755),
                                          file("F/Tiny", "binary", link: "Versions/Current/Tiny", mode: 0o755)],
                                folderLinks: ["F/Versions/Current": "A"])

        XCTAssertEqual(tree.entries, [TreeManifestEntry(path: "F/Tiny", symbolicLinkTarget: "Versions/Current/Tiny"),
                                      TreeManifestEntry(path: "F/Versions/A/Tiny", hash: "binary", mode: 0o755),
                                      TreeManifestEntry(path: "F/Versions/Current", symbolicLinkTarget: "A")])
    }

    /// A link whose target is not in the tree is the copy a push always made of it — the
    /// bytes it carries, with the mode of what it names — and a link that went through it
    /// as a folder is placed again once it is gone; a folder link naming nothing here is
    /// left out.
    func test_aLinkWhoseTargetIsNotInTheTreeIsTheCopyItCarries() {
        let tree = TreeManifest(placing: [file("include/foo.h", "header", link: "impl/foo.h"),
                                          file("Tiny", "binary", link: "Versions/Current/Tiny", mode: 0o755)],
                                folderLinks: ["Versions/Current": "A", "Headers": "Versions/Current/Headers"])

        XCTAssertEqual(tree.entries, [TreeManifestEntry(path: "Tiny", hash: "binary", mode: 0o755),
                                      TreeManifestEntry(path: "include/foo.h", hash: "header", mode: 0o644)])
    }

    // MARK: - Merging

    /// One link held by two trees is one entry; a link and a file at one path, or a path
    /// below a link, are two trees disagreeing.
    func test_mergingKeepsLinksAndNamesWhereTwoTreesDisagree() {
        let link = TreeManifestEntry(path: "F/Versions/Current", symbolicLinkTarget: "A")

        var agreeing = TreeMerge()
        XCTAssertNil(agreeing.add([link], from: "one"))
        XCTAssertNil(agreeing.add([link], from: "two"))
        XCTAssertNil(agreeing.collisionBelowALink)
        XCTAssertEqual(agreeing.manifest.entries, [link])

        var differing = TreeMerge()
        XCTAssertNil(differing.add([link], from: "one"))
        XCTAssertEqual(differing.add([TreeManifestEntry(path: "F/Versions/Current", hash: "copy", mode: 0o644)], from: "two")?.description,
                       "two trees hold 'F/Versions/Current': one and two")

        var below = TreeMerge()
        XCTAssertNil(below.add([link], from: "one"))
        XCTAssertNil(below.add([TreeManifestEntry(path: "F/Versions/Current/Tiny", hash: "copy", mode: 0o644)], from: "two"))
        XCTAssertEqual(below.collisionBelowALink?.description, "two trees hold 'F/Versions/Current': one and two")
    }

    // MARK: - Metadata

    /// One metadata is one document: keys sorted, and a file's is what it always was.
    func test_metadataIsOneDocument() throws {
        XCTAssertEqual(try FileMetadata(mode: 0o644).jsonString(), #"{"mode":420}"#)
        XCTAssertEqual(try FileMetadata(mode: 0o644, symbolicLinkTarget: "Versions/Current/Tiny").jsonString(),
                       #"{"mode":420,"symbolicLinkTarget":"Versions/Current/Tiny"}"#)
    }
}
