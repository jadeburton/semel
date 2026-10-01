//
//  HeldTreeTests.swift
//  SemelCore
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

/// B-132. A push compares the roots the server holds with the ones it folds from the disk,
/// and skips every subtree where they agree. That is only sound if the two folds agree on
/// every folder, links and modes included, and if a root the engine has not folded again
/// yet is never offered as current.
final class HeldTreeTests: SemelCoreTestCase {

    private var engine: BuildEngine!
    private var disk: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
        disk = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-held-tree-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        engine = nil
        try? FileManager.default.removeItem(at: disk)
        try super.tearDownWithError()
    }

    private func write(_ relativePath: String, _ content: String, mode: mode_t = 0o644) throws {
        let url = disk.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, mode)
    }

    private func link(_ relativePath: String, to target: String) throws {
        try FileManager.default.createSymbolicLink(atPath: disk.appendingPathComponent(relativePath).path,
                                                   withDestinationPath: target)
    }

    /// Everything a push of `folder` sends, as the client sends it, and then the fold.
    private func push(_ folder: String, flushing: Bool = true) throws {
        for entry in FolderOnDisk.read(Path(folder), under: disk.path).entriesToPush {
            if case .folder = entry.kind, let target = entry.symbolicLinkTarget {
                _ = try Folder.pushSymbolicLink(target: target, at: entry.path)
                continue
            }
            let content = try PushedContent(ofFileAt: disk.appendingPathComponent(entry.path.string).path, listedAs: entry)
            _ = try StaticFile.push([UInt8](content.bytes), mode: content.mode,
                                    symbolicLinkTarget: content.symbolicLinkTarget, at: entry.path)
        }
        if flushing {
            try Folder.flushDirtyManifests()
        }
    }

    /// Every folder on disk below `folder`, by path, with the root the disk folds to.
    private func diskRoots(_ folder: String) -> [String: DataObjectHash?] {
        var roots: [String: DataObjectHash?] = [:]
        func visit(_ onDisk: FolderOnDisk) {
            roots[onDisk.path.string] = onDisk.contentRoot
            for case .folder(let subfolder) in onDisk.children {
                visit(subfolder)
            }
        }
        visit(FolderOnDisk.read(Path(folder), under: disk.path))
        return roots
    }

    private func frameworkTree() throws {
        try write("app/Sources/main.swift", "print(1)\n")
        try write("app/Sources/Empty.swift", "")
        try write("app/tools/run.sh", "echo\n", mode: 0o755)
        try write("app/Tiny.framework/Versions/A/Tiny", "binary", mode: 0o755)
        try write("app/Tiny.framework/Versions/A/Headers/Tiny.h", "int tiny(void);\n")
        try link("app/Tiny.framework/Versions/Current", to: "A")
        try link("app/Tiny.framework/Tiny", to: "Versions/Current/Tiny")
        try link("app/Tiny.framework/Headers", to: "Versions/Current/Headers")
    }

    // MARK: - The roots

    /// The roots the engine publishes for what a push sent are the ones the disk folds to,
    /// folder for folder — the executable file, the file link and the folder links, and
    /// the copy of what a folder link names, included.
    func test_everyFoldersHeldRootIsTheRootTheDiskFoldsTo() throws {
        try frameworkTree()
        try push("app")

        let held = try HeldTree.folderRoots(below: Path("app"))

        XCTAssertEqual(held.map(\.path.string).first, "app", "the folder asked about comes first")
        XCTAssertTrue(held.allSatisfy(\.isPinned))
        let disk = diskRoots("app")
        XCTAssertEqual(Set(held.map(\.path.string)), Set(disk.keys))
        for folder in held {
            XCTAssertEqual(folder.contentRoot, disk[folder.path.string] ?? nil, folder.path.string)
        }
    }

    /// Three queries of the graph for the roots, whatever the size of the tree: a folder's
    /// path, the folders below it with their ports, and the dot-named files they hold.
    func test_theRootsCostThreeNodeSelectsHoweverLargeTheTree() throws {
        for folder in 0..<12 {
            for file in 0..<5 {
                try write("big/folder\(folder)/nested/file\(file).txt", "\(folder) \(file)")
            }
        }
        try push("big")

        let before = NodeDataAccess.selectCount.value
        let held = try HeldTree.folderRoots(below: Path("big"))

        XCTAssertEqual(held.count, 1 + 12 * 2)
        XCTAssertEqual(NodeDataAccess.selectCount.value - before, 3)
    }

    /// A root the engine has not folded again since a push is not offered as current, and
    /// neither is any root above it, which folds it; a sibling's is.
    func test_aRootWaitingToBeFoldedIsNotOffered() throws {
        try frameworkTree()
        try push("app")
        try write("app/Sources/main.swift", "print(2)\n")

        try push("app", flushing: false)
        let held = Dictionary(uniqueKeysWithValues: try HeldTree.folderRoots(below: Path("app")).map { ($0.path.string, $0) })

        XCTAssertNil(held["app/Sources"]?.contentRoot)
        XCTAssertNil(held["app"]?.contentRoot)
        XCTAssertNotNil(held["app/tools"]?.contentRoot, "a folder the change is not below keeps its root")
    }

    // MARK: - A dot-named file a formula names (B-77 item 5)

    /// A dot-named file pushed by its path is in its folder's root, so the roots name it,
    /// and the disk folded with it agrees with the engine; folded without it, as a walk
    /// leaves dot-names out, the folder differs. A dot-name nobody pushed — a file only on
    /// disk, or one a formula names and nobody pushed — is named by no root.
    func test_aPushedDotNamedFileIsNamedByItsFolderAndFoldedOnBothSides() throws {
        try frameworkTree()
        try write("app/.all-contributorsrc", "{\"contributors\": []}\n")
        try write("app/Sources/.hidden", "never pushed")
        try push("app")
        let hiddenPath = disk.appendingPathComponent("app/.all-contributorsrc").path
        let entry = try XCTUnwrap(ExternalFileSystemLister(rootDirectoryPath: disk.path)
            .hiddenFile(named: ".all-contributorsrc", inDirectoryPath: disk.appendingPathComponent("app").path))
        let content = try PushedContent(ofFileAt: hiddenPath, listedAs: entry)
        _ = try StaticFile.push([UInt8](content.bytes), mode: content.mode, at: Path("app/.all-contributorsrc"))
        try Folder.flushDirtyManifests()

        let held = Dictionary(uniqueKeysWithValues: try HeldTree.folderRoots(below: Path("app")).map { ($0.path.string, $0) })
        XCTAssertEqual(held["app"]?.hiddenFiles, [".all-contributorsrc"])
        XCTAssertEqual(held["app/Sources"]?.hiddenFiles, [], "a dot-named file only on disk is named by no root")

        let told = FolderOnDisk.read(Path("app"), under: disk.path, hiddenFiles: ["app": [".all-contributorsrc"]])
        XCTAssertNotNil(told.contentRoot)
        XCTAssertEqual(told.contentRoot, held["app"]?.contentRoot)
        XCTAssertTrue(told.entriesToPush.contains { $0.path.string == "app/.all-contributorsrc" })
        let untold = FolderOnDisk.read(Path("app"), under: disk.path)
        XCTAssertNotEqual(untold.contentRoot, held["app"]?.contentRoot)
        XCTAssertFalse(untold.entriesToPush.contains { $0.path.lastComponent?.hasPrefix(".") == true })

        let ghost = Path(Folder.inputFileSystemName) / Path("app/Sources/.gitignore")
        _ = try GraphSpecNode.parse("StaticFile(path: '\(ghost.string)')").findOrCreateMatchingNode()
        try Folder.flushDirtyManifests()
        let withGhost = try HeldTree.folderRoots(below: Path("app")).first { $0.path.string == "app/Sources" }
        XCTAssertEqual(withGhost?.hiddenFiles, [], "a dot-named file a formula names and nobody pushed is named by no root")
    }

    func test_noFolderAtThePathHoldsNoRoots() throws {
        XCTAssertEqual(try HeldTree.folderRoots(below: Path("nowhere")), [])
        XCTAssertNil(try HeldTree.children(ofFolderAt: Path("nowhere")))
    }

    // MARK: - The children

    /// What a push compares a file by — its hash, mode and link — and a folder by — its
    /// pin and link.
    func test_aFoldersChildrenCarryWhatAPushComparesThemBy() throws {
        try frameworkTree()
        try push("app")

        let children = try XCTUnwrap(try HeldTree.children(ofFolderAt: Path("app/Tiny.framework")))
        let byName = Dictionary(uniqueKeysWithValues: children.map { ($0.name, $0) })

        XCTAssertEqual(byName["Tiny"], HeldTree.Child(name: "Tiny", kind: .file, contentHash: Sha256.hash(Data("binary".utf8)),
                                                      mode: 0o755, symbolicLinkTarget: "Versions/Current/Tiny", isPinned: true))
        XCTAssertEqual(byName["Headers"], HeldTree.Child(name: "Headers", kind: .folder, contentHash: nil, mode: nil,
                                                         symbolicLinkTarget: "Versions/Current/Headers", isPinned: true))
        XCTAssertEqual(byName["Versions"]?.symbolicLinkTarget, nil)

        let tools = try XCTUnwrap(try HeldTree.children(ofFolderAt: Path("app/tools")))
        XCTAssertEqual(tools, [HeldTree.Child(name: "run.sh", kind: .file, contentHash: Sha256.hash(Data("echo\n".utf8)),
                                              mode: 0o755, symbolicLinkTarget: nil, isPinned: true)])
    }
}
