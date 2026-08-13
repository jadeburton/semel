//
//  GraphShapeApplierTests.swift
//  build_system_tests
//
//  Turning a shape string into live nodes and wires, and finding the node that already
//  matches one. Node identity lives here.
//

@testable import BuildSystemCore
import XCTest

final class GraphShapeApplierTests: BuildSystemTestCase {

    private var engine: BuildEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let database = try DatabaseLayer()
        engine = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    private var database: DatabaseLayer { engine.database }

    // MARK: - findOrCreate

    func test_theSameShapeTwiceReturnsTheSameNode() throws {
        let shape = "Configuration(role: 'shared').output"
        let (first, _)  = try GraphShapeNode.parse(shape).findOrCreateMatchingNode()
        let (second, _) = try GraphShapeNode.parse(shape).findOrCreateMatchingNode()

        XCTAssertEqual(try first.requireID(), try second.requireID())
    }

    func test_differentArgumentsProduceDifferentNodes() throws {
        let (debug, _)   = try GraphShapeNode.parse("Configuration(role: 'debug').output").findOrCreateMatchingNode()
        let (release, _) = try GraphShapeNode.parse("Configuration(role: 'release').output").findOrCreateMatchingNode()

        XCTAssertNotEqual(try debug.requireID(), try release.requireID())
    }

    func test_creatingANodeAlsoCreatesAndWiresItsUpstream() throws {
        let shape = "Configuration(role: 'consumer', inherit: ['w': Configuration(role: 'upstream').output]).output"
        let (consumer, _) = try GraphShapeNode.parse(shape).findOrCreateMatchingNode()

        let incoming = try database.wire.select(goingToNodeID: try consumer.requireID(),
                                                toSymbolID: try "inherit".asSymbolID())
        XCTAssertEqual(incoming.count, 1, "the upstream should have been created and wired")

        let upstream = try database.node.select(nodeID: try XCTUnwrap(incoming.first).fromNodeID)
        XCTAssertEqual(upstream.properties["role"], "upstream")
    }

    func test_reusingAnExistingUpstreamRatherThanDuplicatingIt() throws {
        let (upstream, _) = try GraphShapeNode.parse("Configuration(role: 'upstream').output")
            .findOrCreateMatchingNode()

        let shape = "Configuration(role: 'consumer', inherit: ['w': Configuration(role: 'upstream').output]).output"
        let (consumer, _) = try GraphShapeNode.parse(shape).findOrCreateMatchingNode()

        let incoming = try database.wire.select(goingToNodeID: try consumer.requireID(),
                                                toSymbolID: try "inherit".asSymbolID())
        XCTAssertEqual(try XCTUnwrap(incoming.first).fromNodeID, try upstream.requireID(),
                       "an identical upstream must be shared, not duplicated")
    }

    func test_anUnknownTypeNameIsRejected() throws {
        XCTAssertThrowsError(
            try GraphShapeNode.parse("NoSuchNodeType(role: 'x').output").findOrCreateMatchingNode()
        ) { error in
            guard case GraphShapeApplierError.unknownTypeName(let name) = error else {
                return XCTFail("expected unknownTypeName, got \(error)")
            }
            XCTAssertEqual(name, "NoSuchNodeType")
        }
    }

    func test_aPortTheImplementationDoesNotHaveIsRejected() throws {
        let shape = "Configuration(role: 'x', noSuchPort: ['w': Configuration(role: 'y').output]).output"

        XCTAssertThrowsError(try GraphShapeNode.parse(shape).findOrCreateMatchingNode(),
                             "a formula naming a port that does not exist should not create a node")
    }

    // MARK: - Shape built from the live graph

    func test_aCreatedNodesShapeMatchesTheKeyItWasCreatedWith() throws {
        let shape = "Configuration(role: 'roundtrip').output"
        let (node, _) = try GraphShapeNode.parse(shape).findOrCreateMatchingNode()

        let rebuilt = try GraphShapeNode.buildFromNode(database: database, nodeID: try node.requireID())
            .asString(omitOutputPort: true)

        XCTAssertEqual(rebuilt, node.searchKey,
                       "the shape read back from the graph should be the one stored as the key")
    }

    // MARK: - searchKey drift
    //
    // findMatchingNode is only ever the searchKey lookup — the structural comparison in
    // this file (matchesNode, findMatchingNodeBruteForce) is private and never called.
    // The key is written once at creation and there is no recompute pass, so a node whose
    // static wiring later changes keeps advertising the shape it had when it was born.

    func test_theStoredKeyGoesStaleWhenAStaticInputIsRewired() throws {
        let originalShape = "Configuration(role: 'consumer', inherit: ['w': Configuration(role: 'first').output]).output"
        let (consumer, _) = try GraphShapeNode.parse(originalShape).findOrCreateMatchingNode()
        let keyAtCreation = try XCTUnwrap(consumer.searchKey)

        // Rewire the static input to a different upstream, as applyExpectationConfiguration
        // does when a formula changes.
        let existing = try XCTUnwrap(database.wire.select(goingToNodeID: try consumer.requireID(),
                                                          toSymbolID: try "inherit".asSymbolID()).first)
        try existing.deleteWire(database: database)

        let (second, _) = try GraphShapeNode.parse("Configuration(role: 'second').output")
            .findOrCreateMatchingNode()
        try Wire.connectWire(database: database,
                             fromNodeID: try second.requireID(),
                             fromSymbolID: try "output".asSymbolID(),
                             toNodeID: try consumer.requireID(),
                             toSymbolID: try "inherit".asSymbolID(),
                             name: try "w".asSymbolID())

        let liveShape = try GraphShapeNode.buildFromNode(database: database,
                                                         nodeID: try consumer.requireID())
            .asString(omitOutputPort: true)
        let storedKey = try XCTUnwrap(database.node.select(nodeID: try consumer.requireID())).searchKey

        XCTAssertNotEqual(liveShape, storedKey,
                          "the node's live wiring no longer matches the key it is stored under")
        XCTAssertEqual(storedKey, keyAtCreation,
                       "and the key was never recomputed")
    }

    /// The consequence: a shape describing wiring the node no longer has still resolves
    /// to it, because the lookup only consults the frozen key.
    func test_aStaleKeyStillResolvesToTheRewiredNode() throws {
        let originalShape = "Configuration(role: 'consumer', inherit: ['w': Configuration(role: 'first').output]).output"
        let (consumer, _) = try GraphShapeNode.parse(originalShape).findOrCreateMatchingNode()

        let existing = try XCTUnwrap(database.wire.select(goingToNodeID: try consumer.requireID(),
                                                          toSymbolID: try "inherit".asSymbolID()).first)
        try existing.deleteWire(database: database)

        let match = try GraphShapeNode.parse(originalShape).findMatchingNode()

        XCTAssertEqual(match?.fromNodeID, try consumer.requireID(),
                       "the old shape still finds the node even though that wiring is gone")
    }
}
