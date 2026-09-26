//
//  GraphSpecApplierTests.swift
//  semel_tests
//
//  Turning a spec string into live nodes and wires, and finding the node that already
//  matches one. Node identity lives here.
//

@testable import SemelCore
import XCTest
import SemelNodeKit

final class GraphSpecApplierTests: SemelCoreTestCase {

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
        let spec = "Configuration(role: 'shared').output"
        let (first, _)  = try GraphSpecNode.parse(spec).findOrCreateMatchingNode()
        let (second, _) = try GraphSpecNode.parse(spec).findOrCreateMatchingNode()

        XCTAssertEqual(try first.requireID(), try second.requireID())
    }

    func test_differentArgumentsProduceDifferentNodes() throws {
        let (debug, _)   = try GraphSpecNode.parse("Configuration(role: 'debug').output").findOrCreateMatchingNode()
        let (release, _) = try GraphSpecNode.parse("Configuration(role: 'release').output").findOrCreateMatchingNode()

        XCTAssertNotEqual(try debug.requireID(), try release.requireID())
    }

    func test_creatingANodeAlsoCreatesAndWiresItsUpstream() throws {
        let spec = "Configuration(role: 'consumer', base: ['w': Configuration(role: 'upstream').output]).output"
        let (consumer, _) = try GraphSpecNode.parse(spec).findOrCreateMatchingNode()

        let incoming = try database.wire.select(goingToNodeID: try consumer.requireID(),
                                                toSymbolID: "base".asSymbolID())
        XCTAssertEqual(incoming.count, 1, "the upstream should have been created and wired")

        let upstream = try database.node.select(nodeID: try XCTUnwrap(incoming.first).fromNodeID)
        XCTAssertEqual(upstream.properties["role"], "upstream")
    }

    func test_reusingAnExistingUpstreamRatherThanDuplicatingIt() throws {
        let (upstream, _) = try GraphSpecNode.parse("Configuration(role: 'upstream').output")
            .findOrCreateMatchingNode()

        let spec = "Configuration(role: 'consumer', base: ['w': Configuration(role: 'upstream').output]).output"
        let (consumer, _) = try GraphSpecNode.parse(spec).findOrCreateMatchingNode()

        let incoming = try database.wire.select(goingToNodeID: try consumer.requireID(),
                                                toSymbolID: "base".asSymbolID())
        XCTAssertEqual(try XCTUnwrap(incoming.first).fromNodeID, try upstream.requireID(),
                       "an identical upstream must be shared, not duplicated")
    }

    func test_anUnknownTypeNameIsRejected() throws {
        XCTAssertThrowsError(
            try GraphSpecNode.parse("NoSuchNodeType(role: 'x').output").findOrCreateMatchingNode()
        ) { error in
            guard case GraphSpecApplierError.unknownTypeName(let name) = error else {
                return XCTFail("expected unknownTypeName, got \(error)")
            }
            XCTAssertEqual(name, "NoSuchNodeType")
        }
    }

    func test_aPortTheImplementationDoesNotHaveIsRejected() throws {
        let spec = "Configuration(role: 'x', noSuchPort: ['w': Configuration(role: 'y').output]).output"

        XCTAssertThrowsError(try GraphSpecNode.parse(spec).findOrCreateMatchingNode(),
                             "a formula naming a port that does not exist should not create a node")
    }

    // MARK: - Spec built from the live graph

    func test_aCreatedNodesShapeMatchesTheKeyItWasCreatedWith() throws {
        let spec = "Configuration(role: 'roundtrip').output"
        let (node, _) = try GraphSpecNode.parse(spec).findOrCreateMatchingNode()

        let rebuilt = try GraphSpecNode.buildFromNode(database: database, nodeID: try node.requireID())
            .asString(omitOutputPort: true)

        XCTAssertEqual(rebuilt, node.graphSpec,
                       "the spec read back from the graph should be the one stored as the key")
    }

    /// A node's live spec must always topology-match the key it is stored under.
    ///
    /// This is the invariant the whole identity scheme rests on: the key is written once
    /// at creation and never recomputed, which is only sound because a node's static
    /// wiring and args are immutable. If this ever fails, `expectTopologyMatch` and
    /// `findMatchingNode` can disagree about the same node — which is exactly the
    /// disagreement `applySpecs` papers over as a "false positive".
    func test_aLiveShapeTopologyMatchesItsOwnStoredKey() throws {
        let specs = [
            "Configuration(role: 'plain').output",
            "Configuration(role: 'consumer', base: ['w': Configuration(role: 'up').output]).output",
            "Configuration(role: 'two', base: ['a': Configuration(role: 'x').output]).output",
        ]

        for spec in specs {
            let (node, _) = try GraphSpecNode.parse(spec).findOrCreateMatchingNode()
            let live = try GraphSpecNode.buildFromNode(database: database,
                                                        nodeID: try node.requireID())
            let stored = try GraphSpecNode.parse(try XCTUnwrap(node.graphSpec))

            XCTAssertNoThrow(try live.expectTopologyMatch(stored),
                             "live spec disagrees with the stored key for \(spec)")
        }
    }

    // MARK: - The invariant that makes a frozen key sound
    //
    // A graphSpec is written once at creation and never recomputed. That is correct only
    // while a node's static wiring and args cannot change: static topology is identity, so
    // different static wiring is a different node. Only dynamic ports are rewired after
    // creation, and they are deliberately excluded from the spec.
    //
    // The two tests below reach past the engine and mutate static wiring directly. Nothing
    // in the engine does this — applySpecs only ever touches ports
    // declared `.dynamic`. They exist to show what breaks if that invariant is ever
    // violated, so the cost is visible before someone rewires a static port.

    func test_theStoredKeyGoesStaleIfAStaticInputIsRewired() throws {
        let originalShape = "Configuration(role: 'consumer', base: ['w': Configuration(role: 'first').output]).output"
        let (consumer, _) = try GraphSpecNode.parse(originalShape).findOrCreateMatchingNode()
        let keyAtCreation = try XCTUnwrap(consumer.graphSpec)

        // Rewire the static input directly. Note the engine never does this — only
        // dynamic ports are rewired after creation.
        let existing = try XCTUnwrap(database.wire.select(goingToNodeID: try consumer.requireID(),
                                                          toSymbolID: "base".asSymbolID()).first)
        try existing.deleteWire(database: database)

        let (second, _) = try GraphSpecNode.parse("Configuration(role: 'second').output")
            .findOrCreateMatchingNode()
        try Wire.connectWire(database: database,
                             fromNodeID: try second.requireID(),
                             fromSymbolID: "output".asSymbolID(),
                             toNodeID: try consumer.requireID(),
                             toSymbolID: "base".asSymbolID(),
                             name: "w".asSymbolID())

        let liveShape = try GraphSpecNode.buildFromNode(database: database,
                                                         nodeID: try consumer.requireID())
            .asString(omitOutputPort: true)
        let storedKey = try XCTUnwrap(database.node.select(nodeID: try consumer.requireID())).graphSpec

        XCTAssertNotEqual(liveShape, storedKey,
                          "the node's live wiring no longer matches the key it is stored under")
        XCTAssertEqual(storedKey, keyAtCreation,
                       "and the key was never recomputed")
    }

    /// And the consequence if it were: a spec describing wiring the node no longer has
    /// to it, because the lookup only consults the frozen key.
    func test_aStaleKeyStillResolvesToTheRewiredNode() throws {
        let originalShape = "Configuration(role: 'consumer', base: ['w': Configuration(role: 'first').output]).output"
        let (consumer, _) = try GraphSpecNode.parse(originalShape).findOrCreateMatchingNode()

        let existing = try XCTUnwrap(database.wire.select(goingToNodeID: try consumer.requireID(),
                                                          toSymbolID: "base".asSymbolID()).first)
        try existing.deleteWire(database: database)

        let match = try GraphSpecNode.parse(originalShape).findMatchingNode()

        XCTAssertEqual(match?.fromNodeID, try consumer.requireID(),
                       "the old spec still finds the node even though that wiring is gone")
    }
}
