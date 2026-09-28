//
//  FileSystemRootCacheTests.swift
//  SemelCoreTests
//
//  Folder.root(named:) caches the two file-system root node IDs, because it sits on the
//  hottest path there is — every resolveFolderID, so every StaticFile and Folder init.
//
//  These tests exist because the cache looks safer than it is. Both roots seem constant:
//  reset() preserves them explicitly and no user command can name one. Both assumptions are
//  wrong in a way that fails silently rather than loudly, so the validation on the cached
//  ID is not defensive padding — remove it and this file goes red.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class FileSystemRootCacheTests: SemelCoreTestCase {

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

    /// The roots are collectable. `canBePinned()` asks whether the containing path is under
    /// `input:`, and a root's containing path is empty — so it is false for the roots
    /// themselves, and one with no children and no output wires can be collected. Caching
    /// an ID and trusting it turned the next lookup into `nodeNotFound`.
    func test_aRootIsRebuiltAfterTheCollectorTakesIt() throws {
        let originalID = try engine.inputFileSystem.requireID()

        _ = try engine.database.node.delete(nodeID: originalID)

        let rebuilt = try Folder.inputFileSystem
        XCTAssertEqual(rebuilt.properties["path"], Folder.inputFileSystemName)
        XCTAssertNoThrow(try rebuilt.requireID())
    }

    /// The nastier one. Every test builds a fresh database and a fresh database reissues low
    /// rowids, so an ID carried over from the previous one resolves to a real node that is
    /// not this root. Checking only that the row exists would return it and be believed.
    func test_aCachedIDIsNotBelievedWhenItNamesSomethingElse() throws {
        let rootID = try engine.inputFileSystem.requireID()

        // Stand something else on that row: exactly what a fresh database does when it
        // reissues the same rowid for a different node.
        _ = try engine.database.node.delete(nodeID: rootID)
        let (impostor, _) = try GraphSpecNode(SettingsLiteral.self, properties: ["path": "input:"])
            .findOrCreateMatchingNode()

        let resolved = try Folder.inputFileSystem

        XCTAssertNotEqual(try resolved.requireID(), try impostor.requireID(),
                          "a row that is not a Folder must not be accepted as the root")
        XCTAssertEqual(resolved.kind, Folder.kind)
        XCTAssertEqual(resolved.properties["path"], Folder.inputFileSystemName)
    }

    /// The point of the cache: the same root, resolved twice, is the same node — not a
    /// second one created because the first was not found.
    func test_resolvingARootTwiceGivesTheSameNode() throws {
        let first  = try Folder.inputFileSystem
        let second = try Folder.inputFileSystem

        XCTAssertEqual(try first.requireID(), try second.requireID())
    }

    func test_theTwoRootsAreDistinct() throws {
        let input  = try Folder.inputFileSystem
        let output = try Folder.outputFileSystem

        XCTAssertNotEqual(try input.requireID(), try output.requireID())
        XCTAssertEqual(input.properties["path"],  Folder.inputFileSystemName)
        XCTAssertEqual(output.properties["path"], Folder.outputFileSystemName)
    }
}
