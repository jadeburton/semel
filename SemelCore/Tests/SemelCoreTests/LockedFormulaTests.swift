//
//  LockedFormulaTests.swift
//  SemelCoreTests
//
//  B-143 (c). A formula below a locked folder is a vendored package's own, shipped with it:
//  `ProjectFinder` makes no builder for it, and a notice names it. A real processing loop,
//  because the builders come from the finder reading the pushed listings.
//

@testable import SemelCore
import SemelNodeKit
import XCTest

final class LockedFormulaTests: SemelCoreTestCase {

    private var engine: BuildEngine!
    private let notices = NoticeLog()

    /// The notices the engine gave, captured on the loop's task and read on the test's.
    private final class NoticeLog {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ line: String) {
            lock.withLock { storage.append(line) }
        }

        var skipped: [String] {
            lock.withLock { storage.filter { $0.contains("below a locked folder") } }
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        let database = try DatabaseLayer()
        engine = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
        engine.noticeReporter = { [notices] line in notices.append(line) }
        engine.startProcessingLoop()
        engine.waitUntilIdleBlocking()
    }

    override func tearDown() {
        engine.stopProcessingLoop()
        engine.waitUntilIdleBlocking()
        engine = nil
        super.tearDown()
    }

    /// Pushes every file in one batch, as `push` of a folder does, and waits for the settle.
    private func push(_ files: [String: String]) throws {
        engine.beginBatch()
        do {
            defer {
                engine.endBatch()
            }
            for (relativePath, contents) in files.sorted(by: { $0.key < $1.key }) {
                _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(
                        Path(relativePath).deletingLastComponent ?? .empty, pinned: true)
                let fullPath = Path(Folder.inputFileSystemName) / Path(relativePath)
                let (node, _) = try GraphSpecNode.parse("StaticFile(path: '\(fullPath.string)')").findOrCreateMatchingNode()
                _ = try XCTUnwrap(node.nodeAsAny() as? StaticFile).replaceContent(try contents.intern())
            }
        }
        engine.waitUntilIdleBlocking()
    }

    /// The folders a builder was made for, by its `outputFolder`.
    private func builtFolders() throws -> [String] {
        try DatabaseLayer.shared.node.select(kind: ProjectBuilder.kind)
            .compactMap { $0.properties[ProjectBuilder.outputFolderProperty] }
            .sorted()
    }

    private let product = "product 'notes.txt' = StaticFile(path: <notes.txt>).output"

    /// The tree's own formula is built; the one a locked package ships, at any depth below
    /// it, is not, and the notice names it with the folder whose lock it is under.
    func test_aFormulaBelowALockedFolderIsNotBuiltAndIsNamed() throws {
        try push(["App/semel.fmla":                            product,
                  "App/notes.txt":                             "app",
                  "App/Dependencies/Pkg.semel-lock":           "content sha256:00\nfold x\n",
                  "App/Dependencies/Pkg/semel.fmla":           product,
                  "App/Dependencies/Pkg/notes.txt":            "pkg",
                  "App/Dependencies/Pkg/Examples/demo.fmla":   product])

        XCTAssertEqual(try builtFolders(), ["input:/App"])
        XCTAssertEqual(notices.skipped.last,
                       "Not built, below a locked folder: input:/App/Dependencies/Pkg/Examples/demo.fmla "
                       + "(in input:/App/Dependencies/Pkg), input:/App/Dependencies/Pkg/semel.fmla (in input:/App/Dependencies/Pkg)")
    }

    /// The rule is the lock, not the folder's name: a folder with no lock beside it is the
    /// tree's own, wherever it is, and its formula is built.
    func test_aFormulaBelowAnUnlockedFolderIsBuilt() throws {
        try push(["App/Dependencies/Local/semel.fmla": product,
                  "App/Dependencies/Local/notes.txt":  "local"])

        XCTAssertEqual(try builtFolders(), ["input:/App/Dependencies/Local"])
        XCTAssertEqual(notices.skipped, [])
    }

    /// A lock beside a file names no folder, and locks nothing.
    func test_aLockBesideNoFolderLocksNothing() {
        let manifests: [(String, FolderManifest)] = [
            ("input:/App", FolderManifest(baseFolderPath: "input:/App", entries: [
                FolderManifestEntry(name: "Pkg", isFolder: false, isPinned: true),
                FolderManifestEntry(name: "Pkg.semel-lock", isFolder: false, isPinned: true),
                FolderManifestEntry(name: "Other", isFolder: true, isPinned: true),
                FolderManifestEntry(name: "Locked", isFolder: true, isPinned: true),
                FolderManifestEntry(name: "Locked.semel-lock", isFolder: false, isPinned: true),
            ])),
        ]

        XCTAssertEqual(ProjectFinder.lockedFolders(in: manifests), ["input:/App/Locked"])
    }
}
