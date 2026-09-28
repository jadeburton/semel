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
        let spec = "SettingsLiteral(role: 'shared').output"
        let (first, _)  = try GraphSpecNode.parse(spec).findOrCreateMatchingNode()
        let (second, _) = try GraphSpecNode.parse(spec).findOrCreateMatchingNode()

        XCTAssertEqual(try first.requireID(), try second.requireID())
    }

    func test_differentArgumentsProduceDifferentNodes() throws {
        let (debug, _)   = try GraphSpecNode.parse("SettingsLiteral(role: 'debug').output").findOrCreateMatchingNode()
        let (release, _) = try GraphSpecNode.parse("SettingsLiteral(role: 'release').output").findOrCreateMatchingNode()

        XCTAssertNotEqual(try debug.requireID(), try release.requireID())
    }

    func test_creatingANodeAlsoCreatesAndWiresItsUpstream() throws {
        let spec = "ConfigFilter(prefix: 'consumer', input: ['w': SettingsLiteral(role: 'upstream').output]).output"
        let (consumer, _) = try GraphSpecNode.parse(spec).findOrCreateMatchingNode()

        let incoming = try database.wire.select(goingToNodeID: try consumer.requireID(),
                                                toSymbolID: "input".asSymbolID())
        XCTAssertEqual(incoming.count, 1, "the upstream should have been created and wired")

        let upstream = try database.node.select(nodeID: try XCTUnwrap(incoming.first).fromNodeID)
        XCTAssertEqual(upstream.properties["role"], "upstream")
    }

    func test_reusingAnExistingUpstreamRatherThanDuplicatingIt() throws {
        let (upstream, _) = try GraphSpecNode.parse("SettingsLiteral(role: 'upstream').output")
            .findOrCreateMatchingNode()

        let spec = "ConfigFilter(prefix: 'consumer', input: ['w': SettingsLiteral(role: 'upstream').output]).output"
        let (consumer, _) = try GraphSpecNode.parse(spec).findOrCreateMatchingNode()

        let incoming = try database.wire.select(goingToNodeID: try consumer.requireID(),
                                                toSymbolID: "input".asSymbolID())
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

    /// A table's row naming a type this Semel does not link is the same error a tree
    /// naming one is — asked before the graph is, so it does not matter whether anything
    /// carries the identity the row is filed under.
    func test_aTableRowNamingAnUnknownTypeIsRejectedAsATreeIs() throws {
        let identity = String(repeating: "e", count: 64)
        let table = GraphSpecTable(inputWireSpecs: [:],
                                   rows: [identity: .init(typeName: "NoSuchNodeType", properties: [], inputs: [])])
        var applier = GraphSpecTableApplier(table: table, database: database)

        XCTAssertThrowsError(try applier.node(identity: identity)) { error in
            guard case GraphSpecApplierError.unknownTypeName("NoSuchNodeType") = error else {
                return XCTFail("expected unknownTypeName, got \(error)")
            }
        }
    }

    /// A tree that names a shared node twice makes it once and wires it twice: the tree is
    /// folded into one row for it, and the applier finds or makes each row once.
    func test_aNodeATreeReachesTwiceIsMadeOnce() throws {
        let spec = "ConfigMerger(base: ['a': ConfigFilter(prefix: 'a', input: ['s': SettingsLiteral(role: 'shared').output]).output], "
                 + "override: ['b': ConfigFilter(prefix: 'b', input: ['s': SettingsLiteral(role: 'shared').output]).output]).output"
        _ = try GraphSpecNode.parse(spec).findOrCreateMatchingNode()

        let literals = try database.node.selectAll().filter { $0.properties["role"] == "shared" }
        XCTAssertEqual(literals.count, 1)
        XCTAssertEqual(try database.wire.select(comingFromNodeID: try XCTUnwrap(literals.first).requireID()).count, 2)
        XCTAssertEqual(GraphCheck.run(database: database).findings.filter { $0.kind == .staleIdentity }, [])
    }

    func test_aPortTheImplementationDoesNotHaveIsRejected() throws {
        let spec = "SettingsLiteral(role: 'x', noSuchPort: ['w': SettingsLiteral(role: 'y').output]).output"

        XCTAssertThrowsError(try GraphSpecNode.parse(spec).findOrCreateMatchingNode(),
                             "a formula naming a port that does not exist should not create a node")
    }

    // MARK: - The identity, computed two ways (B-115)

    /// The identity the applier stores is the hash of the demanded tree; the one the graph
    /// gives back — the row and its wires, one level, over the sources' own identities —
    /// is the same number. Three parties agree: the demand, the row, and the recomputation.
    func test_aCreatedNodesIdentityIsTheOneItsRowAndWiresGiveIt() throws {
        let spec = "SettingsLiteral(role: 'roundtrip').output"
        let (node, _) = try GraphSpecNode.parse(spec).findOrCreateMatchingNode()

        XCTAssertEqual(node.identity, try GraphSpecNode.parse(spec).identity())
        XCTAssertEqual(try node.recomputedIdentity(database: database), node.identity)
    }

    /// The invariant the identity scheme rests on: the stored identity is written once at
    /// creation and never recomputed, which is sound because a node's static wiring and
    /// properties are immutable. `check` asks the recomputation whether it still holds.
    func test_aLiveNodesRecomputedIdentityMatchesItsStoredOne() throws {
        let specs = [
            "SettingsLiteral(role: 'plain').output",
            "ConfigFilter(prefix: 'consumer', input: ['w': SettingsLiteral(role: 'up').output]).output",
            "ConfigFilter(prefix: 'two', input: ['a': SettingsLiteral(role: 'x').output]).output",
        ]

        for spec in specs {
            let (node, _) = try GraphSpecNode.parse(spec).findOrCreateMatchingNode()

            XCTAssertEqual(try node.recomputedIdentity(database: database), node.identity,
                           "the recomputed identity disagrees with the stored one for \(spec)")
        }
    }

    // MARK: - The invariant that makes a frozen identity sound
    //
    // An identity is written once at creation and never recomputed. That is correct only
    // while a node's static wiring and properties cannot change: static topology is
    // identity, so different static wiring is a different node. Only dynamic ports are
    // rewired after creation, and they are deliberately outside the identity.
    //
    // The two tests below reach past the engine and mutate static wiring directly. Nothing
    // in the engine does this — applySpecs only ever touches ports declared `.dynamic`.
    // They exist to show what breaks if that invariant is ever violated, so the cost is
    // visible before someone rewires a static port.

    func test_theStoredIdentityGoesStaleIfAStaticInputIsRewired() throws {
        let originalShape = "ConfigFilter(prefix: 'consumer', input: ['w': SettingsLiteral(role: 'first').output]).output"
        let (consumer, _) = try GraphSpecNode.parse(originalShape).findOrCreateMatchingNode()
        let keyAtCreation = try XCTUnwrap(consumer.identity)

        // Rewire the static input directly. Note the engine never does this — only
        // dynamic ports are rewired after creation.
        let existing = try XCTUnwrap(database.wire.select(goingToNodeID: try consumer.requireID(),
                                                          toSymbolID: "input".asSymbolID()).first)
        try existing.deleteWire(database: database)

        let (second, _) = try GraphSpecNode.parse("SettingsLiteral(role: 'second').output")
            .findOrCreateMatchingNode()
        try Wire.connectWire(database: database,
                             fromNodeID: try second.requireID(),
                             fromSymbolID: "output".asSymbolID(),
                             toNodeID: try consumer.requireID(),
                             toSymbolID: "input".asSymbolID(),
                             name: "w".asSymbolID())

        let rewired = try database.node.select(nodeID: try consumer.requireID())

        XCTAssertNotEqual(try rewired.recomputedIdentity(database: database), rewired.identity,
                          "the node's live wiring no longer gives the identity it is stored under")
        XCTAssertEqual(rewired.identity, keyAtCreation,
                       "and the identity was never recomputed")
    }

    /// And the consequence if it were: a spec describing wiring the node no longer has
    /// to it, because the lookup only consults the frozen key.
    func test_aStaleKeyStillResolvesToTheRewiredNode() throws {
        let originalShape = "ConfigFilter(prefix: 'consumer', input: ['w': SettingsLiteral(role: 'first').output]).output"
        let (consumer, _) = try GraphSpecNode.parse(originalShape).findOrCreateMatchingNode()

        let existing = try XCTUnwrap(database.wire.select(goingToNodeID: try consumer.requireID(),
                                                          toSymbolID: "input".asSymbolID()).first)
        try existing.deleteWire(database: database)

        let (match, _) = try GraphSpecNode.parse(originalShape).findOrCreateMatchingNode()

        XCTAssertEqual(try match.requireID(), try consumer.requireID(),
                       "the old spec still finds the node even though that wiring is gone")
    }
}
