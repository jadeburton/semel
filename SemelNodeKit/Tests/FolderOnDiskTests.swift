//
//  FolderOnDiskTests.swift
//  SemelNodeKitTests
//
//  B-132. A push walks the disk once, folds every folder as the engine will fold the
//  pushed copy, and sends from the same walk what the server lacks. The order it sends in
//  is the order a push always sent in, which is the matcher's; the roots are the fold's.
//

@testable import SemelNodeKit
import XCTest

final class FolderOnDiskTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-folder-on-disk-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func write(_ relativePath: String, _ content: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func link(_ relativePath: String, to target: String) throws {
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(relativePath).path,
                                                   withDestinationPath: target)
    }

    private func frameworkTree() throws {
        try write("tree/b.txt", "b")
        try write("tree/a/one.txt", "one")
        try write("tree/a/.hidden", "hidden")
        try write("tree/Fw/Versions/A/Tiny", "binary")
        try link("tree/Fw/Versions/Current", to: "A")
        try link("tree/Fw/Tiny", to: "Versions/Current/Tiny")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tree/empty/deeper"),
                                                withIntermediateDirectories: true)
    }

    /// What a push sent before it compared anything: every file below, and every folder
    /// that is a link, as the matcher found them — and nothing else, in the same order.
    func test_whatItWouldPushIsWhatTheMatcherFinds() throws {
        try frameworkTree()
        let matcher = FileWildcardMatcher(input: ExternalFileSystemLister(rootDirectoryPath: root.path))
        let matched = try matcher.findAllMatching(pathOrWildcard: "tree/**/*").filter {
            $0.kind == .file || $0.symbolicLinkTarget != nil
        }

        let onDisk = FolderOnDisk.read(Path("tree"), under: root.path)

        XCTAssertEqual(onDisk.entriesToPush.map(\.path.string), matched.map(\.path.string))
        XCTAssertEqual(onDisk.entriesToPush.map(\.symbolicLinkTarget), matched.map(\.symbolicLinkTarget))
        XCTAssertEqual(onDisk.fileCount, matched.count)
    }

    /// Each folder carries the root the lock fold gives it on its own, and a folder link
    /// carries the root of what it names — the copy a push stores below it.
    func test_eachFoldersRootIsItsOwnFold() throws {
        try frameworkTree()

        let onDisk = FolderOnDisk.read(Path("tree"), under: root.path)

        XCTAssertEqual(onDisk.contentRoot, try FolderContentRoot.root(ofFolderAt: root.appendingPathComponent("tree")))
        let framework = try XCTUnwrap(subfolder(named: "Fw", of: onDisk))
        let versions  = try XCTUnwrap(subfolder(named: "Versions", of: framework))
        let current   = try XCTUnwrap(subfolder(named: "Current", of: versions))
        XCTAssertEqual(current.symbolicLinkTarget, "A")
        XCTAssertEqual(current.contentRoot, try FolderContentRoot.root(ofFolderAt: root.appendingPathComponent("tree/Fw/Versions/A")))
        XCTAssertNil(subfolder(named: "empty", of: onDisk), "a folder a push would not make is not here")
    }

    /// The export folder a build writes into the tree is left out of the walk, and so of the
    /// root: the server never holds it, and a root with it would never match.
    func test_anExcludedFolderIsLeftOutOfTheWalkAndTheRoot() throws {
        try write("tree/src/main.c", "int main;")
        let before = FolderOnDisk.read(Path("tree"), under: root.path).contentRoot

        try write("tree/semel-out/product", "built")
        let excluding = FolderOnDisk.read(Path("tree"), under: root.path) { $0.string.hasPrefix("tree/semel-out") }

        XCTAssertEqual(excluding.contentRoot, before)
        XCTAssertFalse(excluding.entriesToPush.contains { $0.path.string.hasPrefix("tree/semel-out") })
    }

    /// A dot-named file the server holds is walked and folded where the disk has it, in
    /// the order the folder's other files are, and the folders above it fold it in; one it
    /// does not hold, or a name that is not on disk, leaves the walk as it was. The lock's
    /// fold of the same folder is told of none, so it leaves every dot-name out (B-77 item 5).
    func test_aDotNamedFileTheServerHoldsIsWalkedAndFolded() throws {
        try frameworkTree()
        let untold = FolderOnDisk.read(Path("tree"), under: root.path)

        let told = FolderOnDisk.read(Path("tree"), under: root.path, hiddenFiles: ["tree/a": [".hidden", ".gone"]])

        XCTAssertEqual(told.entriesToPush.map(\.path.string).filter { $0.hasPrefix("tree/a/") },
                       ["tree/a/.hidden", "tree/a/one.txt"])
        XCTAssertNotEqual(told.contentRoot, untold.contentRoot)
        let folder = try XCTUnwrap(subfolder(named: "a", of: told))
        let hiddenHash = Sha256.hash(Data("hidden".utf8))
        let oneHash    = Sha256.hash(Data("one".utf8))
        let expected = FolderContentRoot.document(of: [
            (".hidden", .file, .file(hash: hiddenHash, mode: PushedContent.mode(ofFileAt: root.appendingPathComponent("tree/a/.hidden").path))),
            ("one.txt", .file, .file(hash: oneHash, mode: PushedContent.mode(ofFileAt: root.appendingPathComponent("tree/a/one.txt").path))),
        ])
        XCTAssertEqual(folder.contentRoot, Sha256.hash(Data(expected.utf8)))
        XCTAssertEqual(untold.contentRoot, try FolderContentRoot.root(ofFolderAt: root.appendingPathComponent("tree")),
                       "the lock's fold leaves dot-names out")
    }

    /// A folder with its lock beside it has the dot-named files the lock names walked as
    /// well, whether the walk starts above the lock or inside the locked folder, and folds
    /// to the root `prepare` records for the folder told the same names (B-143).
    func test_aDotNamedFileALockNamesIsWalkedAndFolded() throws {
        try write("app/Dependencies/Pkg/Sources/Kit/.config", "declared")
        try write("app/Dependencies/Pkg/Sources/Kit/Kit.swift", "kit")
        try write("app/Dependencies/Pkg/.swiftlint.yml", "not declared")
        let lock = DependencyLock(contentRoot: "abc", fold: FolderContentRoot.formatTag, hiddenFiles: ["Sources/Kit/.config"])
        try write("app/Dependencies/Pkg.semel-lock", lock.text)

        for start in ["app", "app/Dependencies/Pkg", "app/Dependencies/Pkg/Sources"] {
            let pushed = FolderOnDisk.read(Path(start), under: root.path).entriesToPush.map(\.path.string)
            XCTAssertTrue(pushed.contains("app/Dependencies/Pkg/Sources/Kit/.config"), "\(start): \(pushed)")
            XCTAssertFalse(pushed.contains("app/Dependencies/Pkg/.swiftlint.yml"), "\(start): \(pushed)")
        }
        let package = root.appendingPathComponent("app/Dependencies/Pkg")
        let walked = FolderOnDisk.read(Path("app/Dependencies/Pkg"), under: root.path)
        XCTAssertEqual(walked.contentRoot, try FolderContentRoot.root(ofFolderAt: package, hiddenFiles: lock.hiddenFiles))
        XCTAssertNotEqual(walked.contentRoot, try FolderContentRoot.root(ofFolderAt: package))
    }

    private func subfolder(named name: String, of folder: FolderOnDisk) -> FolderOnDisk? {
        for case .folder(let subfolder) in folder.children where subfolder.path.lastComponent == name {
            return subfolder
        }
        return nil
    }
}
