//
//  FolderQueryPlanTests.swift
//  SemelCore
//

@testable import SemelCore
@testable import SemelDatabaseModels
import Foundation
import GRDB
import SemelNodeKit
import XCTest

/// The plans SQLite chooses for the two queries a push runs per folder and per file: a
/// folder's ports by child (`selectChildPorts`, every fold) and the path to a file
/// (`selectPath`, every file). Without statistics the planner had both of them read the
/// graph — every port of a name, every node — so a cold push cost the square of its tree.
///
/// The plan asked about is the one of the statement the accessor actually ran, caught by
/// tracing the connection, so the test does not keep a copy of the SQL to drift from it.
final class FolderQueryPlanTests: SemelCoreTestCase {

    private var engine: BuildEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let database = try DatabaseLayer()
        engine = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
        for index in 0..<20 {
            _ = try StaticFile.push(Array("file \(index)".utf8), mode: FileMetadata.defaultMode,
                                    at: Path("src/sub\(index % 3)/file\(index).c"))
        }
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    private var database: DatabaseLayer { engine.database }

    func test_aFoldReadsTheFoldersChildrenAndNotEveryPortOfTheName() throws {
        let folderID = try XCTUnwrap(engine.inputFileSystem.childNode(path: "src/sub0")).requireID()
        let plan = try planOfTheStatement {
            _ = try database.node.selectChildPorts(parentNodeID: folderID, nameSymbolID: StaticFile.outputPort.asSymbolID())
        }

        XCTAssertTrue(plan.first?.contains("parentNodeID=?") == true,
                      "the folder's children have to be the outer loop, got:\n\(plan.joined(separator: "\n"))")
        XCTAssertTrue(plan.contains { $0.contains("nodeID=? AND nameSymbolID=?") },
                      "each child's port has to be a lookup by key, got:\n\(plan.joined(separator: "\n"))")
    }

    func test_aFoldByNameReadsTheFoldersChildrenAndNotEveryPortOfTheName() throws {
        let folderID = try XCTUnwrap(engine.inputFileSystem.childNode(path: "src")).requireID()
        let plan = try planOfTheStatement {
            _ = try database.node.selectChildPortsByName(parentNodeID: folderID,
                                                         nameSymbolID: Folder.subtreeManifestOutputPort.asSymbolID())
        }

        XCTAssertTrue(plan.first?.contains("parentNodeID=?") == true,
                      "the folder's children have to be the outer loop, got:\n\(plan.joined(separator: "\n"))")
        XCTAssertTrue(plan.contains { $0.contains("nodeID=? AND nameSymbolID=?") },
                      "each child's port has to be a lookup by key, got:\n\(plan.joined(separator: "\n"))")
    }

    func test_aPathIsReadByLookupsAndNeverByAScanOfTheNodes() throws {
        let rootID = try engine.inputFileSystem.requireID()
        let plan = try planOfTheStatement {
            _ = try database.node.selectPath(below: rootID, names: ["src", "sub1", "file1.c"],
                                             portSymbolIDs: [StaticFile.outputPort.asSymbolID()])
        }

        XCTAssertFalse(plan.contains { $0.hasPrefix("SCAN n") || $0.hasPrefix("SCAN Node") },
                       "no step of the walk may read the whole table, got:\n\(plan.joined(separator: "\n"))")
        XCTAssertTrue(plan.contains { $0.hasPrefix("SEARCH n USING INTEGER PRIMARY KEY") },
                      "each node on the path has to be read by its id, got:\n\(plan.joined(separator: "\n"))")
    }

    // MARK: - Helpers

    /// The query plan of the one statement `work` ran, a line per step.
    private func planOfTheStatement(_ work: () throws -> Void) throws -> [String] {
        let recorder = StatementRecorder()
        database.dbQueue.inDatabase { db in
            db.trace(options: .statement) { event in
                if case .statement(let statement) = event {
                    recorder.texts.append(statement.expandedSQL)
                }
            }
        }
        defer {
            database.dbQueue.inDatabase { db in db.trace(options: [], nil) }
        }
        try work()

        let selects = recorder.texts.filter { $0.contains("SELECT") }
        XCTAssertEqual(selects.count, 1, "the accessor should run one select, ran: \(selects)")
        let sql = try XCTUnwrap(selects.first)
        return try database.dbQueue.inDatabase { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql).map { $0["detail"] as String? ?? "" }
        }
    }

    private final class StatementRecorder {
        var texts: [String] = []
    }
}
