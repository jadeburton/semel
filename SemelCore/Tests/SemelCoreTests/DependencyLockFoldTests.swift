//
//  DependencyLockFoldTests.swift
//  SemelCore
//

@testable import SemelCore
import SemelNodeKit
import XCTest

/// B-06. `semel-swift prepare` folds a vendored folder on disk into the root it writes in the
/// lock, and the converter compares that with the root the engine publishes for the pushed
/// copy. The two are only ever equal if the disk fold reads what a push pushes, so this
/// pushes a tree the way `push` does — every file `<folder>/**/*` matches, through the
/// lister `push` matches with — and compares the two roots.
final class DependencyLockFoldTests: SemelCoreTestCase {

    private var engine: BuildEngine!
    private var disk: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
        disk = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-lock-fold-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        engine = nil
        try? FileManager.default.removeItem(at: disk)
        try super.tearDownWithError()
    }

    private func write(_ relativePath: String, _ content: String) throws {
        let url = disk.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// What `push <folder>` stores, as the client and the server store it: each file the
    /// matcher finds under it at its path, with its bytes, mode and — for a link inside its
    /// folder — its target, and each folder that is such a link as one (B-77).
    private func push(_ folder: String) throws {
        let matcher = FileWildcardMatcher(input: ExternalFileSystemLister(rootDirectoryPath: disk.path))
        for entry in try matcher.findAllMatching(pathOrWildcard: "\(folder)/**/*") {
            switch entry.kind {
            case .folder:
                guard let target = entry.symbolicLinkTarget else {
                    continue
                }
                _ = try Folder.pushSymbolicLink(target: target, at: entry.path)
            case .file:
                let content = try PushedContent(ofFileAt: disk.appendingPathComponent(entry.path.string).path, listedAs: entry)
                _ = try StaticFile.push([UInt8](content.bytes), mode: content.mode,
                                        symbolicLinkTarget: content.symbolicLinkTarget, at: entry.path)
            }
        }
        try Folder.flushDirtyManifests()
    }

    private func engineRoot(of folder: String) throws -> DataObjectHash {
        let node = try XCTUnwrap(try engine.inputFileSystem.childNode(path: Path(folder)))
        return try node.readFromOutputPort(Folder.contentRootOutputPort).expectValue()
    }

    /// A vendored checkout's shape: nested sources, an empty file, a small file whose name in
    /// the store is its own bytes, dot-files a push leaves out and a folder holding nothing
    /// a push would push.
    func test_theRootPrepareRecordsIsTheRootTheEnginePublishesForThePushedCopy() throws {
        try write("Dependencies/GRDB.swift/Package.swift", "// swift-tools-version: 5.9\nimport PackageDescription\n")
        try write("Dependencies/GRDB.swift/GRDB/Core/Database.swift", "public final class Database {}\n")
        try write("Dependencies/GRDB.swift/GRDB/Core/Empty.swift", "")
        try write("Dependencies/GRDB.swift/Sources/GRDBSQLite/module.modulemap", "module GRDBSQLite [system] {}\n")
        try write("Dependencies/GRDB.swift/tiny", "x")
        try write("Dependencies/GRDB.swift/.gitignore", ".build\n")
        try write("Dependencies/GRDB.swift/.github/workflows/ci.yml", "on: push\n")
        try write("Dependencies/GRDB.swift/Documentation/.keep", "")
        try FileManager.default.createDirectory(at: disk.appendingPathComponent("Dependencies/GRDB.swift/Empty/Deeper"),
                                                withIntermediateDirectories: true)

        try push("Dependencies/GRDB.swift")

        XCTAssertEqual(try FolderContentRoot.root(ofFolderAt: disk.appendingPathComponent("Dependencies/GRDB.swift")),
                       try engineRoot(of: "Dependencies/GRDB.swift"))
    }

    /// A vendored binary artifact's framework, as a vendor builds one: `Versions/A`, the
    /// `Versions/Current` link to it, and the links at its top to what is in it — beside a
    /// link out of the package, which a push follows. Each link inside its folder is pushed
    /// as one, what it names pushed below it as always, and the engine folds the tree the
    /// disk folds (B-77).
    func test_aTreeHoldingLinksFoldsTheSameInTheEngineAsOnDisk() throws {
        let framework = "Dependencies/Sparkle/semel-artifacts/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
        try write("Dependencies/Sparkle/Package.swift", "// swift-tools-version: 5.9\n")
        try write("\(framework)/Versions/B/Sparkle", "binary")
        try write("\(framework)/Versions/B/Headers/Sparkle.h", "header")
        try write("\(framework)/Versions/B/Resources/Info.plist", "plist")
        try write("Shared/outside.h", "outside")
        let fileManager = FileManager.default
        let frameworkURL = disk.appendingPathComponent(framework)
        try fileManager.createSymbolicLink(atPath: frameworkURL.appendingPathComponent("Versions/Current").path,
                                           withDestinationPath: "B")
        for name in ["Sparkle", "Headers", "Resources"] {
            try fileManager.createSymbolicLink(atPath: frameworkURL.appendingPathComponent(name).path,
                                               withDestinationPath: "Versions/Current/\(name)")
        }
        try fileManager.createSymbolicLink(atPath: disk.appendingPathComponent("Dependencies/Sparkle/outside.h").path,
                                           withDestinationPath: "../../Shared/outside.h")

        try push("Dependencies/Sparkle")

        let pushedRoot = try engineRoot(of: "Dependencies/Sparkle")
        XCTAssertEqual(try FolderContentRoot.root(ofFolderAt: disk.appendingPathComponent("Dependencies/Sparkle")), pushedRoot)

        // And a retargeted link moves both, though nothing it could name changed.
        try fileManager.removeItem(at: frameworkURL.appendingPathComponent("Versions/Current"))
        try write("\(framework)/Versions/C/Sparkle", "binary")
        try write("\(framework)/Versions/C/Headers/Sparkle.h", "header")
        try write("\(framework)/Versions/C/Resources/Info.plist", "plist")
        try fileManager.createSymbolicLink(atPath: frameworkURL.appendingPathComponent("Versions/Current").path,
                                           withDestinationPath: "C")
        try push("Dependencies/Sparkle")

        let moved = try engineRoot(of: "Dependencies/Sparkle")
        XCTAssertNotEqual(moved, pushedRoot)
        XCTAssertEqual(try FolderContentRoot.root(ofFolderAt: disk.appendingPathComponent("Dependencies/Sparkle")), moved)
    }

    /// The other half of the contract: a copy that moved no longer matches, and a file the
    /// disk no longer has is still in the graph a push only adds to.
    func test_aFileRemovedFromDiskAfterThePushNoLongerMatches() throws {
        try write("Dependencies/Nuke/Package.swift", "p\n")
        try write("Dependencies/Nuke/Sources/Old.swift", "old\n")
        try push("Dependencies/Nuke")

        try FileManager.default.removeItem(at: disk.appendingPathComponent("Dependencies/Nuke/Sources/Old.swift"))
        try write("Dependencies/Nuke/Sources/New.swift", "new\n")
        try push("Dependencies/Nuke")

        XCTAssertNotEqual(try FolderContentRoot.root(ofFolderAt: disk.appendingPathComponent("Dependencies/Nuke")),
                          try engineRoot(of: "Dependencies/Nuke"))
    }

    /// A vendored package with no lock is a notice from a toolchain node, which cannot reach
    /// the engine; the engine installs itself behind `NodeNotice` so the line goes where
    /// its own do, and so to the client.
    func test_aNodesNoticeGoesWhereTheEnginesNoticesGo() {
        var said: [String] = []
        engine.noticeReporter = { said.append($0) }

        NodeNotice.post("No lock beside 1 vendored package (GRDB.swift)")

        XCTAssertEqual(said, ["No lock beside 1 vendored package (GRDB.swift)"])
    }
}
