//
//  CachedStatementTests.swift
//  SemelCore
//

@testable import SemelCore
@testable import SemelDatabaseModels
import Foundation
import GRDB
import XCTest

/// The accessors run their statements through the connection's own cache
/// (`CachedStatements.swift`): a text is prepared once and run again, on the connection that
/// prepared it, for as long as that connection — and so its `DatabaseLayer` — lives.
///
/// What is counted is the statements alive on the connection, by text: an accessor that
/// prepared afresh on every call would leave none behind, and one that cached across
/// connections would show its text on a connection that never ran it.
final class CachedStatementTests: SemelCoreTestCase {

    private static let childSummariesText = "SELECT id, kind, name FROM Node WHERE parentNodeID = ?"

    func test_anAccessorPreparesItsStatementOnceAndRunsItAgain() throws {
        let database = try DatabaseLayer()
        XCTAssertEqual(statements(Self.childSummariesText, on: database), 0, "fixture: nothing has run it yet")

        try database.withTransaction {
            for parentNodeID in 1...20 {
                _ = try database.node.selectChildSummaries(parentNodeID: ObjectID(parentNodeID))
            }
            XCTAssertEqual(statements(Self.childSummariesText, on: database), 1,
                           "twenty calls inside one transaction run one statement")
        }

        // Outside a transaction each read expires every statement (`PRAGMA query_only`), and
        // SQLite prepares it again in place: still one statement, never one per call.
        for parentNodeID in 1...5 {
            _ = try database.node.selectChildSummaries(parentNodeID: ObjectID(parentNodeID))
        }
        XCTAssertEqual(statements(Self.childSummariesText, on: database), 1)
    }

    func test_aStatementBelongsToTheLayerThatPreparedIt() throws {
        let first  = try DatabaseLayer()
        let parent = try first.node.insert(NodeRecord(kind: Folder.kind, name: "parent", identity: "parent"))
        _ = try first.node.insert(NodeRecord(parentNodeID: parent, kind: StaticFile.kind, name: "child", identity: "child"))
        XCTAssertEqual(try first.node.selectChildSummaries(parentNodeID: parent).map(\.name), ["child"])

        let second = try DatabaseLayer()
        XCTAssertEqual(statements(Self.childSummariesText, on: second), 0,
                       "a new layer's connection holds nothing another connection prepared")
        XCTAssertEqual(try second.node.selectChildSummaries(parentNodeID: parent).count, 0,
                       "and what it runs reads its own database")
        XCTAssertEqual(statements(Self.childSummariesText, on: second), 1)

        XCTAssertEqual(try first.node.selectChildSummaries(parentNodeID: parent).map(\.name), ["child"],
                       "the first layer goes on reading its own rows through its own statement")
        XCTAssertEqual(statements(Self.childSummariesText, on: first), 1)
    }

    /// An accessor holds its layer weakly, and a statement lives in the layer's connection,
    /// so an accessor kept past its layer has nothing to run a statement on: it says so
    /// rather than reaching for another connection's.
    func test_anAccessorKeptPastItsLayerRunsNothing() throws {
        var layer: DatabaseLayer? = try DatabaseLayer()
        weak var released = layer
        let accessor = try XCTUnwrap(layer).node
        _ = try accessor.selectChildSummaries(parentNodeID: 1)

        layer = try DatabaseLayer()     // replaces `DatabaseLayer.shared`, the other owner
        layer = nil
        XCTAssertNil(released, "fixture: nothing else holds the first layer")

        XCTAssertThrowsError(try accessor.selectChildSummaries(parentNodeID: 1)) { error in
            guard case DatabaseLayer.DatabaseError.layerReleased = error else {
                return XCTFail("expected layerReleased, got \(error)")
            }
        }
    }

    /// SQLite cannot reset a statement whose step failed, and GRDB drops such a statement
    /// from the cache: the next call prepares the text afresh and runs as it would have.
    func test_aStatementThatFailedIsPreparedAgainForTheNextCall() throws {
        let database = try DatabaseLayer()
        let firstID  = try database.node.insert(NodeRecord(kind: Folder.kind, name: "first", identity: "first"))
        let secondID = try database.node.insert(NodeRecord(kind: Folder.kind, name: "second", identity: "second"))
        var second   = try database.node.select(nodeID: secondID)

        second.identity = "first"
        XCTAssertThrowsError(try database.node.update(second), "identity is unique")

        second.identity = "renamed"
        try database.node.update(second)
        XCTAssertEqual(try database.node.select(nodeID: secondID).identity, "renamed")
        XCTAssertEqual(try database.node.select(nodeID: firstID).identity, "first")
    }

    /// A nil parent asks for the nodes that have none, as the query it replaced did.
    func test_aLookupByNameUnderNoParentFindsTheNodesWithNone() throws {
        let database = try DatabaseLayer()
        let rootID   = try database.node.insert(NodeRecord(kind: Folder.kind, name: "root", identity: "root"))
        _ = try database.node.insert(NodeRecord(parentNodeID: rootID, kind: Folder.kind, name: "root", identity: "nested"))

        XCTAssertEqual(try database.node.select(named: "root", parentNodeID: nil).map(\.id), [rootID])
        XCTAssertEqual(try database.node.select(kind: Folder.kind, named: "root", parentNodeID: nil).map(\.id), [rootID])
        XCTAssertEqual(try database.node.select(named: "root", parentNodeID: rootID).count, 1)
    }

    // MARK: - Helpers

    /// How many statements with exactly `text` are alive on the layer's connection.
    private func statements(_ text: String, on database: DatabaseLayer) -> Int {
        database.preparedStatementTexts().filter { $0 == text }.count
    }
}
