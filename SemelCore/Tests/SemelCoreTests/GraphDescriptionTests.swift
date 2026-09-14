//
//  GraphDescriptionTests.swift
//  SemelCoreTests
//
//  The debug dump is a string, not a side effect, so a server can send it to whichever
//  client asked. The content is a diagnostic and not pinned line by line; these tests
//  check that the sections are there and that a node shows up under its type.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class GraphDescriptionTests: SemelCoreTestCase {

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

    func test_describesAnEmptyGraphWithItsSections() throws {
        let text = try engine.graphDescription()

        XCTAssertTrue(text.hasPrefix("BUILD GRAPH STATE ("), text)
        XCTAssertTrue(text.contains("OutputPort count: "), text)
        XCTAssertTrue(text.contains("- build tree"), text)
    }

    func test_listsANodeUnderItsTypeName() throws {
        _ = try NodeRecord.createNode(database: engine.database, kind: StaticFile.kind,
                                      properties: ["path": "input:/a.c"], graphSpec: nil)

        let text = try engine.graphDescription()

        XCTAssertTrue(text.contains("⬢ StaticFile #"), text)
        XCTAssertTrue(text.contains("name: 'input:/a.c'") || text.contains("graphSpec:"), text)
    }
}
