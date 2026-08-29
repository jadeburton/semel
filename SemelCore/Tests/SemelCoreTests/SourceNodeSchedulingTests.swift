//
//  SourceNodeSchedulingTests.swift
//  SemelCoreTests
//
//  What separates a node the graph processes from one it does not.
//
//  This used to be carried by the type system — two protocols, and only a `NodeFunction`
//  was ever scheduled. Now there is one protocol and the answer comes from
//  `descriptor.hasInputs`, so nothing checks it at compile time any more. These tests are
//  what is left holding it.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class SourceNodeSchedulingTests: SemelCoreTestCase {

    private var engine: BuildEngine!
    private var database: DatabaseLayer { engine.database }

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
        try PolyFactory.register(types: [SampleSourceNode.self])
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    private func createNode(kind: UInt) throws -> Node {
        try Node.createNode(database: database, kind: kind, properties: [:], searchKey: nil)
    }

    /// A node with no input ports has nothing to be handed, so creating it must not queue
    /// work. Scheduling one would have the engine call `process` on a node with no inputs.
    func test_aNodeWithNoInputPortsIsNotScheduledWhenCreated() throws {
        let node = try createNode(kind: SampleSourceNode.kind)

        XCTAssertFalse(try database.node.select(nodeID: node.requireID()).scheduled)
    }

    /// The other half: a node that does take inputs is still scheduled on creation, which is
    /// how anything gets built at all.
    func test_aNodeWithInputPortsIsScheduledWhenCreated() throws {
        let node = try createNode(kind: SampleTool.kind)

        XCTAssertTrue(try database.node.select(nodeID: node.requireID()).scheduled)
    }

    /// Asking directly is refused too, not merely skipped at creation — `nudge` and the
    /// wire-change path both go through `setScheduled`.
    func test_aNodeWithNoInputPortsCannotBeScheduledOnRequest() throws {
        let node = try createNode(kind: SampleSourceNode.kind)

        try node.setScheduled(true)

        XCTAssertFalse(try database.node.select(nodeID: node.requireID()).scheduled)
    }

    /// The descriptor is the whole distinction now, so it is worth stating outright.
    func test_hasInputsIsTheDistinction() {
        XCTAssertFalse(SampleSourceNode.descriptor.hasInputs)
        XCTAssertTrue(SampleTool.descriptor.hasInputs)
        XCTAssertFalse(StaticFile.descriptor.hasInputs)
        XCTAssertFalse(Folder.descriptor.hasInputs)
    }
}
