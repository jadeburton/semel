//
//  FolderDeletabilityScaleTests.swift
//  SemelCoreTests
//
//  B-24. `FolderDeletabilityTests` pins what `canBeDeleted` answers; this file pins what
//  reaching the answer costs. The leaves are free — one query per kind settles every file
//  and every subfolder's own pinned state — but descending into an unpinned subfolder
//  fetches its row and builds a `Folder` around it, so a tree costs a node per subfolder
//  in it and nothing per file.
//
//  Two shapes tell a per-subfolder cost apart from anything worse: a tree twenty levels
//  deep, which is double the depth of a real one, and a tree two hundred folders wide.
//  Asserted as a count of instantiations rather than in seconds, for the reason
//  `FolderRemovalScaleTests` gives: a stopwatch has to be given a band wide enough to
//  survive a loaded machine. The seconds are measured all the same and quoted in the
//  failure message.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class FolderDeletabilityScaleTests: SemelCoreTestCase {

    /// Deeper than any tree the collector meets: the IceCubes tree is under ten levels, so
    /// twenty is double the depth of a real one and the count has room to show a bend.
    private static let depth = 20

    /// Wide enough that a per-subfolder cost is unmistakable beside a per-level one.
    private static let width = 200

    /// Enough files at each level that the leaves are a population rather than a special
    /// case, and few enough that building the fixture is not the test.
    private static let filesPerFolder = 3

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

    // MARK: - What the descent costs

    /// A chain of folders costs one `Folder` per level and nothing per file. This is the
    /// recursion B-24 describes, at twice the depth of a real tree.
    func test_aDeepTreeCostsOneFolderPerLevel() throws {
        let cost = try costOfCheckingDeletability(of: try buildDeepTree())

        XCTAssertTrue(cost.deletable, "fixture: nothing in the tree objects — \(cost.described)")
        XCTAssertEqual(cost.instantiations, Self.depth,
                       "one node per level below the root, and none for the files — "
                       + cost.described)
    }

    /// A fan of folders costs one `Folder` per subfolder, which at one level of nesting is
    /// also one per level of *descent* — the count follows the subfolders in the tree, not
    /// the files, and not the subfolders squared.
    func test_aWideTreeCostsOneFolderPerSubfolderAndNothingPerFile() throws {
        let cost = try costOfCheckingDeletability(of: try buildWideTree())

        XCTAssertTrue(cost.deletable, "fixture: nothing in the tree objects — \(cost.described)")
        XCTAssertEqual(cost.instantiations, Self.width,
                       "one node per subfolder, and none for the \(Self.width * Self.filesPerFolder)"
                       + " files under them — " + cost.described)
    }

    // MARK: - What one check cost

    /// The `Folder` values one deletability check built, the answer it came to, and the
    /// seconds it took — carried for a failure message to quote, never asserted on.
    private struct CheckCost {
        let shape:          String
        let instantiations: Int
        let deletable:      Bool
        let seconds:        TimeInterval

        var described: String {
            "\(shape): \(instantiations) Folder instantiations in"
            + " \(String(format: "%.3f", seconds))s, deletable: \(deletable)"
        }
    }

    /// Builds the root `Folder` first, so the one instantiation the caller needs to ask the
    /// question is outside the window, and measures the check alone.
    private func costOfCheckingDeletability(of rootPath: String) throws -> CheckCost {
        let root = try folder(rootPath)

        let instantiatedBefore = Folder.instantiationCount.value
        let start = Date.now
        let deletable = try root.canBeDeleted()
        let seconds = Date.now.timeIntervalSince(start)

        return CheckCost(shape: rootPath,
                         instantiations: Folder.instantiationCount.value - instantiatedBefore,
                         deletable: deletable,
                         seconds: seconds)
    }

    // MARK: - The trees

    /// A chain `depth` folders long, files at every level. Every folder is unpinned and
    /// every file is a ghost, so nothing objects and the check walks the whole tree —
    /// stopping at the first objection is what `FolderDeletabilityTests` covers, and a
    /// tree that objected early would measure nothing.
    private func buildDeepTree() throws -> String {
        var path = "deep"
        try pushGhosts(into: path)
        for level in 0 ..< Self.depth {
            path += "/level\(level)"
            try pushGhosts(into: path)
        }
        return "deep"
    }

    /// `width` folders side by side under one root, files in each.
    private func buildWideTree() throws -> String {
        try pushGhosts(into: "wide")
        for index in 0 ..< Self.width {
            try pushGhosts(into: "wide/branch\(index)")
        }
        return "wide"
    }

    /// Files nobody pushed content into, under folders nobody pinned: the state a name the
    /// graph refers to and the user never wrote is in, and the one that lets a folder go.
    private func pushGhosts(into folderPath: String) throws {
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(Path(folderPath), pinned: false)

        for index in 0 ..< Self.filesPerFolder {
            let fullPath = Path(Folder.inputFileSystemName) / Path("\(folderPath)/file\(index).c")
            _ = try GraphSpecNode.parse("StaticFile(path: '\(fullPath.string)')")
                .findOrCreateMatchingNode()
        }
    }

    private func folder(_ relativePath: String) throws -> Folder {
        let node = try XCTUnwrap(engine.inputFileSystem.childNode(path: Path(relativePath)))
        return try XCTUnwrap(node.nodeAsAny() as? Folder)
    }
}
